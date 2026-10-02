import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_session_cubit_test.dart' show MockBridgeService;

const _thread = 'durable-overlay-queue';
const _runtime = 'runtime-overlay-queue';
const _authority = 'authority-overlay-queue';
const _source = 'bridge-a/source-a';
const _turn = 'turn-overlay-queue';

ConversationSyncV2Status _status({
  String activity = 'working',
  String? turn = _turn,
  String authority = _authority,
  String runtime = _runtime,
  String at = '2026-10-03T00:00:01.000Z',
}) => ConversationSyncV2Status(
  provider: 'codex',
  providerSessionId: _thread,
  activity: activity,
  attention: 'none',
  result: 'none',
  runtimeAttachment: 'loaded',
  source: 'bridgeRuntime',
  confidence: 'authoritative',
  observedAt: at,
  executionHost: 'bridge',
  activeTurnId: activity == 'working' ? turn : null,
  controlState: activity == 'working' ? 'steerable' : 'writable',
  authorityGeneration: authority,
  runtimeSessionId: runtime,
);

int _wireBytes(String text) =>
    utf8.encode(jsonEncode({'type': 'error', 'message': text})).length;

String _textForWireBytes(int bytes) {
  // Include real multibyte input: UTF-16 length is not a byte budget.
  const prefix = '中文';
  return prefix + 'x' * (bytes - _wireBytes(prefix));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockBridgeService bridge;
  late StreamingStateCubit streaming;
  late StreamController<ConversationSyncV2EventMessage> overlays;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = MockBridgeService()
      ..advertisedBridgeCapabilities = const {
        conversationSyncV2Capability,
        conversationRuntimeOverlayCapability,
      };
    streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
    overlays = StreamController<ConversationSyncV2EventMessage>.broadcast();
  });

  tearDown(() async {
    await overlays.close();
    await streaming.close();
    bridge.dispose();
  });

  ChatSessionCubit createCubit({bool active = false}) {
    final cubit = ChatSessionCubit(
      sessionId: _thread,
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
      initialLiveRuntimeSessionId: _runtime,
      initialHistoryMessages: const [
        UserInputMessage(text: 'Canonical user', providerItemId: 'queue-user'),
      ],
      detachedRuntimeOverlayStream: overlays.stream,
    );
    addTearDown(() async {
      if (!cubit.isClosed) await cubit.close();
    });
    cubit.updateDetachedProviderStatus(
      _status(
        activity: active ? 'working' : 'idle',
        at: '2026-10-03T00:00:00.000Z',
      ),
      sourceFingerprint: _source,
    );
    return cubit;
  }

  void addOverlay(
    String id,
    String text, {
    String turn = _turn,
    String authority = _authority,
    String runtime = _runtime,
    String source = 'source-a',
    String at = '2026-10-03T00:00:01.000Z',
  }) {
    overlays.add(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.runtimeOverlay,
        subscriptionId: 'queue-subscription',
        bridgeInstanceId: 'bridge-a',
        codexSourceId: source,
        batchId: 'queue-batch',
        sequence: 1,
        provider: 'codex',
        providerSessionId: _thread,
        overlayId: id,
        observedAt: at,
        originGeneration: 'runtime:$runtime:$authority',
        runtimeSessionId: runtime,
        authorityGeneration: authority,
        turnId: turn,
        overlayMessage: ErrorMessage(message: text),
      ),
    );
  }

  List<String> visibleErrors(ChatSessionCubit cubit) => cubit.visibleEntries
      .whereType<ServerChatEntry>()
      .map((entry) => entry.message)
      .whereType<ErrorMessage>()
      .map((message) => message.message)
      .toList();

  void expectPending(ChatSessionCubit cubit, int count, int bytes) {
    final projection =
        cubit.diagnosticRuntimeProjection['timelineProjection']
            as Map<String, Object?>;
    expect(projection['pendingRuntimeOverlayCount'], count);
    expect(projection['pendingRuntimeOverlayBytes'], bytes);
    expect(
      cubit.visibleEntries.whereType<UserChatEntry>().map(
        (entry) => entry.text,
      ),
      ['Canonical user'],
    );
  }

  test(
    '32 pending events retain FIFO; duplicates and the 33rd use no budget',
    () async {
      final cubit = createCubit();
      final texts = [for (var i = 0; i < 32; i++) 'Queued $i'];
      for (var i = 0; i < texts.length; i++) {
        addOverlay('queued-$i', texts[i]);
      }
      addOverlay('queued-0', 'Duplicate must not replace first');
      addOverlay('overflow-count', 'Rejected 33rd');
      await pumpEventQueue();
      expectPending(cubit, 32, texts.map(_wireBytes).reduce((a, b) => a + b));
      expect(visibleErrors(cubit), isEmpty);
      cubit.updateDetachedProviderStatus(_status(), sourceFingerprint: _source);
      expectPending(cubit, 0, 0);
      expect(visibleErrors(cubit), texts);
    },
  );

  test(
    'exact 64 KiB multibyte budget survives incoming overflow and flush',
    () async {
      final cubit = createCubit();
      final first = _textForWireBytes(32767);
      final second = _textForWireBytes(32769);
      expect(_wireBytes(first) + _wireBytes(second), 65536);
      addOverlay('byte-first', first);
      addOverlay('byte-second', second);
      addOverlay('byte-overflow', 'Rejected extra payload');
      await pumpEventQueue();
      expectPending(cubit, 2, 65536);
      expect(visibleErrors(cubit), isEmpty);
      cubit.updateDetachedProviderStatus(_status(), sourceFingerprint: _source);
      expectPending(cubit, 0, 0);
      expect(visibleErrors(cubit), [first, second]);
    },
  );

  test('one 65537-byte event cannot evict an earlier pending event', () async {
    final cubit = createCubit();
    addOverlay('safe-before-oversize', 'Earlier valid payload');
    addOverlay('single-oversize', _textForWireBytes(65537));
    await pumpEventQueue();
    expectPending(cubit, 1, _wireBytes('Earlier valid payload'));
    cubit.updateDetachedProviderStatus(_status(), sourceFingerprint: _source);
    expectPending(cubit, 0, 0);
    expect(visibleErrors(cubit), ['Earlier valid payload']);
  });

  test('proven stale removal releases bytes for a later valid turn', () async {
    final cubit = createCubit();
    addOverlay('old-first', 'Old one');
    addOverlay('old-second', 'Old two');
    await pumpEventQueue();
    expectPending(cubit, 2, _wireBytes('Old one') + _wireBytes('Old two'));
    cubit.updateDetachedProviderStatus(
      _status(turn: 'different-turn', at: '2026-10-03T00:00:02.000Z'),
      sourceFingerprint: _source,
    );
    expectPending(cubit, 0, 0);
    addOverlay(
      'fresh',
      'New turn payload',
      turn: 'new-turn',
      at: '2026-10-03T00:00:03.000Z',
    );
    await pumpEventQueue();
    expectPending(cubit, 1, _wireBytes('New turn payload'));
    cubit.updateDetachedProviderStatus(
      _status(turn: 'new-turn', at: '2026-10-03T00:00:03.000Z'),
      sourceFingerprint: _source,
    );
    expectPending(cubit, 0, 0);
    expect(visibleErrors(cubit), ['New turn payload']);
  });

  test('an applied event replay cannot re-enter quarantine', () async {
    final cubit = createCubit();
    addOverlay('applied-once', 'One payload');
    await pumpEventQueue();
    cubit.updateDetachedProviderStatus(_status(), sourceFingerprint: _source);
    addOverlay('applied-once', 'A replay cannot replace it');
    await pumpEventQueue();
    expectPending(cubit, 0, 0);
    expect(visibleErrors(cubit), ['One payload']);
  });

  for (final reset in ['runtime', 'source', 'suspend']) {
    test(
      '$reset invalidation retires pending bytes and accepts a fresh owner',
      () async {
        final cubit = createCubit();
        addOverlay('before-$reset', 'Retired pending payload');
        await pumpEventQueue();
        expectPending(cubit, 1, _wireBytes('Retired pending payload'));
        final runtime = reset == 'runtime' ? 'runtime-replacement' : _runtime;
        final source = reset == 'source' ? 'source-b' : 'source-a';
        if (reset == 'runtime') {
          cubit.updateDetachedLiveRuntime(runtime);
        } else if (reset == 'source') {
          bridge.sourceId = source;
          cubit.updateDetachedProviderStatus(
            null,
            sourceFingerprint: 'bridge-a/$source',
          );
        } else {
          cubit.suspendDetachedProviderProjection();
        }
        expectPending(cubit, 0, 0);
        cubit.updateDetachedProviderStatus(
          _status(
            activity: 'idle',
            runtime: runtime,
            authority: 'fresh-authority',
            at: '2026-10-03T00:00:02.000Z',
          ),
          sourceFingerprint: 'bridge-a/$source',
        );
        addOverlay(
          'after-$reset',
          'Fresh owner payload',
          runtime: runtime,
          source: source,
          authority: 'fresh-authority',
          at: '2026-10-03T00:00:03.000Z',
        );
        await pumpEventQueue();
        expectPending(cubit, 1, _wireBytes('Fresh owner payload'));
        cubit.updateDetachedProviderStatus(
          _status(
            runtime: runtime,
            authority: 'fresh-authority',
            at: '2026-10-03T00:00:03.000Z',
          ),
          sourceFingerprint: 'bridge-a/$source',
        );
        expectPending(cubit, 0, 0);
        expect(visibleErrors(cubit), ['Fresh owner payload']);
      },
    );
  }

  test('close retires pending bytes and ignores a late overlay', () async {
    final cubit = createCubit();
    addOverlay('before-close', 'Unconfirmed payload');
    await pumpEventQueue();
    expectPending(cubit, 1, _wireBytes('Unconfirmed payload'));
    await cubit.close();
    addOverlay('after-close', 'Late payload');
    await pumpEventQueue();
    expect(cubit.isClosed, isTrue);
    expectPending(cubit, 0, 0);
    expect(visibleErrors(cubit), isEmpty);
  });

  test('authority replacement retires the previous quarantine owner', () async {
    final cubit = createCubit(active: true);
    addOverlay(
      'visible-before-authority',
      'Old authority warning',
      at: '2026-10-03T00:00:00.000Z',
    );
    await pumpEventQueue();
    addOverlay(
      'pending-before-authority',
      'Old authority pending',
      turn: 'next-turn',
      at: '2026-10-03T00:00:02.000Z',
    );
    await pumpEventQueue();
    expectPending(cubit, 1, _wireBytes('Old authority pending'));
    cubit.updateDetachedProviderStatus(
      _status(turn: 'next-turn', authority: 'replacement-authority'),
      sourceFingerprint: _source,
    );
    expectPending(cubit, 0, 0);
    expect(visibleErrors(cubit), isEmpty);
    addOverlay(
      'fresh-authority-event',
      'Replacement authority warning',
      turn: 'next-turn',
      authority: 'replacement-authority',
      at: '2026-10-03T00:00:03.000Z',
    );
    await pumpEventQueue();
    expectPending(cubit, 0, 0);
    expect(visibleErrors(cubit), ['Replacement authority warning']);
  });

  test('turn retirement still rejects a pending event proven older', () async {
    final cubit = createCubit(active: true);
    addOverlay(
      'visible-before-terminal',
      'Retiring warning',
      at: '2026-10-03T00:00:00.000Z',
    );
    await pumpEventQueue();
    addOverlay(
      'stale-pending',
      'Unmatched old payload',
      turn: 'unmatched-turn',
      at: '2026-10-03T00:00:00.500Z',
    );
    await pumpEventQueue();
    expectPending(cubit, 1, _wireBytes('Unmatched old payload'));
    cubit.updateDetachedProviderStatus(
      _status(activity: 'idle'),
      sourceFingerprint: _source,
    );
    expectPending(cubit, 0, 0);
    expect(visibleErrors(cubit), isEmpty);
  });

  for (final oldTerminalFirst in [false, true]) {
    test(
      'next turn quarantine survives ${oldTerminalFirst ? 'old terminal then' : 'direct'} turn replacement',
      () async {
        final cubit = createCubit(active: true);
        addOverlay(
          'old-visible',
          'Previous turn warning',
          at: '2026-10-03T00:00:00.000Z',
        );
        await pumpEventQueue();
        expect(visibleErrors(cubit), ['Previous turn warning']);
        addOverlay(
          'next-pending',
          'Next turn warning',
          turn: 'next-turn',
          at: '2026-10-03T00:00:02.000Z',
        );
        await pumpEventQueue();
        expectPending(cubit, 1, _wireBytes('Next turn warning'));
        if (oldTerminalFirst) {
          cubit.updateDetachedProviderStatus(
            _status(activity: 'idle', at: '2026-10-03T00:00:01.000Z'),
            sourceFingerprint: _source,
          );
          expect(visibleErrors(cubit), isEmpty);
          expectPending(cubit, 1, _wireBytes('Next turn warning'));
        }
        cubit.updateDetachedProviderStatus(
          _status(turn: 'next-turn', at: '2026-10-03T00:00:02.000Z'),
          sourceFingerprint: _source,
        );
        expectPending(cubit, 0, 0);
        expect(visibleErrors(cubit), ['Next turn warning']);
      },
    );
  }
}
