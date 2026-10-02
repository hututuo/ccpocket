import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_layout.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_session_cubit_test.dart' show MockBridgeService;

const _thread = 'durable-terminal-stream';
const _runtime = 'runtime-terminal-stream';
const _authority = 'authority-terminal-stream';
const _turn = 'turn-terminal-stream';
const _source = 'bridge-a/source-a';
const _user = UserInputMessage(
  text: 'Exercise terminal presentation',
  providerItemId: 'user-terminal-stream',
  historyTurnId: _turn,
);

AssistantServerMessage _assistant(String id, String text) =>
    AssistantServerMessage(
      message: AssistantMessage(
        id: id,
        role: 'assistant',
        content: [TextContent(text: text)],
        model: 'gpt-test',
      ),
      historyTurnId: _turn,
    );

ConversationSyncV2Status _status({
  String activity = 'working',
  String observedAt = '2026-10-02T11:00:01.000Z',
  String provider = 'codex',
  String thread = _thread,
  String? authority = _authority,
  String? turn = _turn,
  String source = 'bridgeRuntime',
  String? executionHost = 'bridge',
  String? runtime = _runtime,
}) => ConversationSyncV2Status.fromJson({
  ...ConversationSyncV2Status(
    provider: provider,
    providerSessionId: thread,
    activity: activity,
    attention: 'none',
    result: 'none',
    runtimeAttachment: 'loaded',
    source: source,
    confidence: 'authoritative',
    observedAt: observedAt,
    executionHost: executionHost,
    activeTurnId: activity == 'working' ? turn : null,
    controlState: activity == 'working' ? 'steerable' : 'writable',
    authorityGeneration: authority,
  ).toJson(),
  if (runtime != null) 'runtimeSessionId': runtime,
});

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

  List<ServerMessage> history({bool finalReply = false}) => [
    _user,
    _assistant('assistant-terminal-a', 'First commentary'),
    _assistant('assistant-terminal-b', 'Second commentary'),
    if (finalReply) _assistant('assistant-terminal-final', 'Final answer'),
  ];

  ChatSessionCubit createCubit({bool confirmActiveTurn = true}) {
    final cubit = ChatSessionCubit(
      sessionId: _thread,
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
      initialLiveRuntimeSessionId: _runtime,
      initialHistoryMessages: history(),
      detachedRuntimeOverlayStream: overlays.stream,
    );
    addTearDown(cubit.close);
    cubit.updateDetachedProviderStatus(
      _status(activity: confirmActiveTurn ? 'working' : 'idle'),
      sourceFingerprint: _source,
    );
    return cubit;
  }

  Future<void> streamFinal() async {
    bridge.emitMessage(
      const StreamDeltaMessage(text: 'Final answer'),
      sessionId: _runtime,
    );
    await pumpEventQueue();
    expect(streaming.state.isStreaming, isTrue);
    expect(streaming.state.text, 'Final answer');
  }

  void expectCompletedLayout(ChatSessionCubit cubit) {
    expect(cubit.state.status, ProcessStatus.idle);
    expect(cubit.state.externalDesktopTurnActive, isFalse);
    expect(streaming.state.isStreaming, isFalse);
    expect(streaming.state.text, isEmpty);
    final layout = buildChatProcessLayout(
      cubit.visibleEntries,
      latestTurnIsActive:
          cubit.state.status == ProcessStatus.running ||
          cubit.state.externalDesktopTurnActive ||
          streaming.state.isStreaming,
      hasTransientCurrentOutput: streaming.state.isStreaming,
    ).latestTurn!;
    expect(layout.isActive, isFalse);
    expect(layout.hasTransientCurrentOutput, isFalse);
    expect(layout.intermediateOutputCount, 2);
    expect(layout.finalAssistantEntryIndex, 3);
    expect(layout.intermediateAssistantEntryIndices, {1, 2});
    expect(cubit.visibleEntries.whereType<UserChatEntry>(), hasLength(1));
  }

  for (final canonicalFirst in [true, false]) {
    test(
      'current idle closes streaming with canonical ${canonicalFirst ? 'before' : 'after'} terminal status',
      () async {
        final cubit = createCubit();
        await streamFinal();
        if (canonicalFirst) {
          cubit.updateDetachedPreviewHistory(history(finalReply: true));
        }
        bridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: _runtime,
        );
        await pumpEventQueue();
        cubit.updateDetachedProviderStatus(
          _status(activity: 'idle', observedAt: '2026-10-02T11:00:02.000Z'),
          sourceFingerprint: _source,
        );
        if (!canonicalFirst) {
          cubit.updateDetachedPreviewHistory(history(finalReply: true));
        }
        expectCompletedLayout(cubit);

        // A completion queued before the newer terminal projection cannot
        // reacquire the old turn or append a second canonical final reply.
        overlays.add(
          ConversationSyncV2EventMessage(
            event: ConversationSyncV2EventKind.runtimeOverlay,
            subscriptionId: 'subscription-terminal',
            bridgeInstanceId: 'bridge-a',
            codexSourceId: 'source-a',
            batchId: 'batch-terminal',
            sequence: 10,
            provider: 'codex',
            providerSessionId: _thread,
            overlayId: 'late-final-overlay',
            observedAt: '2026-10-02T11:00:01.500Z',
            originGeneration: 'runtime:$_runtime:$_authority',
            runtimeSessionId: _runtime,
            authorityGeneration: _authority,
            turnId: _turn,
            overlayMessage: _assistant(
              'assistant-terminal-final',
              'Final answer',
            ),
          ),
        );
        await pumpEventQueue();
        expectCompletedLayout(cubit);
      },
    );
  }

  for (final temporarilyAbsent in [false, true]) {
    test(
      'socket completion closes output with ${temporarilyAbsent ? 'temporarily absent' : 'turnless working'} provider projection',
      () async {
        final cubit = createCubit();
        await streamFinal();
        cubit.updateDetachedPreviewHistory(history(finalReply: true));
        if (!temporarilyAbsent) {
          cubit.updateDetachedProviderStatus(
            _status(turn: null, observedAt: '2026-10-02T11:00:01.500Z'),
            sourceFingerprint: _source,
          );
        }
        bridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: _runtime,
        );
        await pumpEventQueue();
        if (temporarilyAbsent) {
          cubit.updateDetachedProviderStatus(null, sourceFingerprint: _source);
        }
        expect(streaming.state.isStreaming, isTrue);
        expect(streaming.state.text, 'Final answer');
        expect(cubit.detachedActionBrokerTurnId, isNull);
        cubit.updateDetachedProviderStatus(
          _status(activity: 'idle', observedAt: '2026-10-02T11:00:02.000Z'),
          sourceFingerprint: _source,
        );
        expectCompletedLayout(cubit);
      },
    );
  }

  for (final evidence in ['missing-authority', 'desktop-host', 'app-server']) {
    test('socket idle does not grant cleanup for $evidence status', () async {
      final cubit = createCubit();
      await streamFinal();
      cubit.updateDetachedPreviewHistory(history(finalReply: true));
      bridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: _runtime,
      );
      await pumpEventQueue();
      cubit.updateDetachedProviderStatus(
        _status(
          activity: 'idle',
          observedAt: '2026-10-02T11:00:02.000Z',
          authority: evidence == 'missing-authority' ? null : _authority,
          executionHost: evidence == 'desktop-host'
              ? 'desktopAppServer'
              : 'bridge',
          source: evidence == 'app-server' ? 'appServer' : 'bridgeRuntime',
        ),
        sourceFingerprint: _source,
      );
      expect(streaming.state.isStreaming, isTrue);
      expect(streaming.state.text, 'Final answer');
    });
  }

  test(
    'ongoing working status and partial canonical preserve live output',
    () async {
      final cubit = createCubit();
      await streamFinal();
      cubit.updateDetachedPreviewHistory(history());
      cubit.updateDetachedProviderStatus(
        _status(observedAt: '2026-10-02T11:00:02.000Z'),
        sourceFingerprint: _source,
      );
      expect(cubit.state.status, ProcessStatus.running);
      expect(streaming.state.isStreaming, isTrue);
      expect(streaming.state.text, 'Final answer');
    },
  );

  test('older idle cannot retire the current working stream', () async {
    final cubit = createCubit();
    await streamFinal();
    cubit.updateDetachedProviderStatus(
      _status(activity: 'idle', observedAt: '2026-10-02T11:00:00.000Z'),
      sourceFingerprint: _source,
    );
    expect(cubit.state.status, ProcessStatus.running);
    expect(streaming.state.isStreaming, isTrue);
    expect(streaming.state.text, 'Final answer');
  });

  test(
    'bootstrap idle cannot retire output before active turn confirmation',
    () async {
      final cubit = createCubit(confirmActiveTurn: false);
      await streamFinal();
      // The socket can already carry a new delta while the status reader is
      // still delivering its earlier bootstrap idle snapshot.
      cubit.updateDetachedProviderStatus(
        _status(activity: 'idle', observedAt: '2026-10-02T11:00:02.000Z'),
        sourceFingerprint: _source,
      );
      expect(streaming.state.isStreaming, isTrue);
      expect(streaming.state.text, 'Final answer');
      cubit.updateDetachedProviderStatus(
        _status(observedAt: '2026-10-02T11:00:03.000Z'),
        sourceFingerprint: _source,
      );
      expect(streaming.state.isStreaming, isTrue);
      bridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: _runtime,
      );
      await pumpEventQueue();
      cubit.updateDetachedProviderStatus(
        _status(activity: 'idle', observedAt: '2026-10-02T11:00:04.000Z'),
        sourceFingerprint: _source,
      );
      expect(streaming.state.isStreaming, isFalse);
      expect(streaming.state.text, isEmpty);
    },
  );

  test(
    'terminal filters uncommitted completion while its overlay identity is intact',
    () async {
      final cubit = createCubit();
      overlays.add(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.runtimeOverlay,
          subscriptionId: 'subscription-terminal',
          bridgeInstanceId: 'bridge-a',
          codexSourceId: 'source-a',
          batchId: 'batch-terminal',
          sequence: 10,
          provider: 'codex',
          providerSessionId: _thread,
          overlayId: 'uncommitted-final-overlay',
          observedAt: '2026-10-02T11:00:01.500Z',
          originGeneration: 'runtime:$_runtime:$_authority',
          runtimeSessionId: _runtime,
          authorityGeneration: _authority,
          turnId: _turn,
          overlayMessage: _assistant(
            'assistant-terminal-final',
            'Final answer',
          ),
        ),
      );
      await pumpEventQueue();
      List<String> assistantIds() => cubit.visibleEntries
          .whereType<ServerChatEntry>()
          .map((entry) => entry.message)
          .whereType<AssistantServerMessage>()
          .map((message) => message.message.id)
          .toList();
      expect(assistantIds(), [
        'assistant-terminal-a',
        'assistant-terminal-b',
        'assistant-terminal-final',
      ]);
      cubit.updateDetachedProviderStatus(
        _status(activity: 'idle', observedAt: '2026-10-02T11:00:02.000Z'),
        sourceFingerprint: _source,
      );
      // Only SQLite history can own completed durable rows after the overlay
      // lease ends. Clearing aliases first must not promote a live row.
      expect(assistantIds(), ['assistant-terminal-a', 'assistant-terminal-b']);
      cubit.updateDetachedPreviewHistory(history(finalReply: true));
      expectCompletedLayout(cubit);
      expect(assistantIds(), [
        'assistant-terminal-a',
        'assistant-terminal-b',
        'assistant-terminal-final',
      ]);
    },
  );

  for (final wrongThread in [true, false]) {
    test(
      'unrelated ${wrongThread ? 'thread' : 'provider'} idle preserves live output',
      () async {
        final cubit = createCubit();
        await streamFinal();
        cubit.updateDetachedProviderStatus(
          _status(
            activity: 'idle',
            observedAt: '2026-10-02T11:00:02.000Z',
            thread: wrongThread ? 'other-thread' : _thread,
            provider: wrongThread ? 'codex' : 'claude',
          ),
          sourceFingerprint: _source,
        );
        expect(cubit.state.status, ProcessStatus.running);
        expect(streaming.state.isStreaming, isTrue);
        expect(streaming.state.text, 'Final answer');
      },
    );
  }

  test(
    'next delta survives a delayed previous-turn terminal projection',
    () async {
      final cubit = createCubit();
      await streamFinal();
      cubit.updateDetachedPreviewHistory(history(finalReply: true));
      overlays.add(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.runtimeOverlay,
          subscriptionId: 'subscription-terminal',
          bridgeInstanceId: 'bridge-a',
          codexSourceId: 'source-a',
          batchId: 'batch-terminal',
          sequence: 10,
          provider: 'codex',
          providerSessionId: _thread,
          overlayId: 'previous-turn-completed',
          observedAt: '2026-10-02T11:00:01.500Z',
          originGeneration: 'runtime:$_runtime:$_authority',
          runtimeSessionId: _runtime,
          authorityGeneration: _authority,
          turnId: _turn,
          overlayMessage: _assistant(
            'assistant-terminal-final',
            'Final answer',
          ),
        ),
      );
      await pumpEventQueue();
      expect(streaming.state.isStreaming, isFalse);
      bridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: _runtime,
      );
      bridge.emitMessage(
        const StatusMessage(status: ProcessStatus.running),
        sessionId: _runtime,
      );
      bridge.emitMessage(
        const StreamDeltaMessage(text: 'Next turn output'),
        sessionId: _runtime,
      );
      await pumpEventQueue();
      cubit.updateDetachedProviderStatus(
        _status(activity: 'idle', observedAt: '2026-10-02T11:00:02.000Z'),
        sourceFingerprint: _source,
      );
      expect(streaming.state.isStreaming, isTrue);
      expect(streaming.state.text, 'Next turn output');
      cubit.updateDetachedProviderStatus(
        _status(turn: 'turn-next', observedAt: '2026-10-02T11:00:03.000Z'),
        sourceFingerprint: _source,
      );
      bridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: _runtime,
      );
      await pumpEventQueue();
      cubit.updateDetachedProviderStatus(
        _status(activity: 'idle', observedAt: '2026-10-02T11:00:04.000Z'),
        sourceFingerprint: _source,
      );
      expect(streaming.state.isStreaming, isFalse);
      expect(streaming.state.text, isEmpty);
    },
  );

  test(
    'coalesced delta after socket idle survives delayed terminal projection',
    () async {
      await streaming.close();
      streaming = StreamingStateCubit(
        coalesceInterval: const Duration(milliseconds: 50),
      );
      fakeAsync((clock) {
        final cubit = createCubit();
        bridge.emitMessage(
          const StreamDeltaMessage(text: 'Visible output'),
          sessionId: _runtime,
        );
        clock.flushMicrotasks();
        bridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: _runtime,
        );
        clock.flushMicrotasks();
        bridge.emitMessage(
          const StreamDeltaMessage(text: ' buffered next output'),
          sessionId: _runtime,
        );
        clock.flushMicrotasks();
        expect(streaming.state.text, 'Visible output');
        cubit.updateDetachedProviderStatus(
          _status(activity: 'idle', observedAt: '2026-10-02T11:00:02.000Z'),
          sourceFingerprint: _source,
        );
        expect(streaming.state.isStreaming, isTrue);
        clock.elapse(const Duration(milliseconds: 50));
        expect(streaming.state.text, 'Visible output buffered next output');
        cubit.updateDetachedProviderStatus(
          _status(turn: 'turn-next', observedAt: '2026-10-02T11:00:03.000Z'),
          sourceFingerprint: _source,
        );
        bridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: _runtime,
        );
        clock.flushMicrotasks();
        cubit.updateDetachedProviderStatus(
          _status(activity: 'idle', observedAt: '2026-10-02T11:00:04.000Z'),
          sourceFingerprint: _source,
        );
        expect(streaming.state.isStreaming, isFalse);
        expect(streaming.state.text, isEmpty);
      });
    },
  );

  for (final cachedBeforeIdle in [false, true]) {
    test(
      'unobserved intermediate runtime cannot retire new output with cache ${cachedBeforeIdle ? 'before' : 'after'} socket idle',
      () async {
        final cubit = createCubit();
        cubit.updateDetachedLiveRuntime('runtime-intermediate');
        cubit.updateDetachedLiveRuntime('runtime-current');
        // No visual existed at either rebind: the original pending-turn
        // validator cannot be responsible for the cleanup being tested.
        expect(
          cubit.diagnosticRuntimeProjection['visualTurnValidationPending'],
          isFalse,
        );
        if (cachedBeforeIdle) {
          cubit.updateDetachedProviderStatus(
            _status(
              authority: 'authority-intermediate',
              runtime: 'runtime-intermediate',
              observedAt: '2026-10-02T11:00:01.500Z',
            ),
            sourceFingerprint: _source,
          );
        }
        bridge.emitMessage(
          const StreamDeltaMessage(text: 'Current runtime output'),
          sessionId: 'runtime-current',
        );
        bridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 'runtime-current',
        );
        await pumpEventQueue();
        cubit.updateDetachedProviderStatus(
          _status(
            activity: 'idle',
            authority: 'authority-intermediate',
            runtime: 'runtime-intermediate',
            observedAt: '2026-10-02T11:00:02.000Z',
          ),
          sourceFingerprint: _source,
        );
        expect(streaming.state.isStreaming, isTrue);
        expect(streaming.state.text, 'Current runtime output');

        // A later snapshot naming the actual bound runtime still completes
        // through the same socket/status path, without recreating the Cubit.
        cubit.updateDetachedProviderStatus(
          _status(
            authority: 'authority-current',
            runtime: 'runtime-current',
            observedAt: '2026-10-02T11:00:03.000Z',
          ),
          sourceFingerprint: _source,
        );
        bridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 'runtime-current',
        );
        await pumpEventQueue();
        cubit.updateDetachedProviderStatus(
          _status(
            activity: 'idle',
            authority: 'authority-current',
            runtime: 'runtime-current',
            observedAt: '2026-10-02T11:00:04.000Z',
          ),
          sourceFingerprint: _source,
        );
        expect(streaming.state.isStreaming, isFalse);
        expect(streaming.state.text, isEmpty);
      },
    );
  }

  test('runtime identity participates in duplicate status fencing', () async {
    final cubit = createCubit();
    await streamFinal();
    bridge.emitMessage(
      const StatusMessage(status: ProcessStatus.idle),
      sessionId: _runtime,
    );
    await pumpEventQueue();
    for (final runtime in ['runtime-other', _runtime]) {
      cubit.updateDetachedProviderStatus(
        _status(
          activity: 'idle',
          runtime: runtime,
          observedAt: '2026-10-02T11:00:02.000Z',
        ),
        sourceFingerprint: _source,
      );
      expect(streaming.state.isStreaming, runtime != _runtime);
    }
    expect(streaming.state.text, isEmpty);
  });

  test('legacy status cannot acquire the new terminal cleanup path', () async {
    final cubit = createCubit();
    await streamFinal();
    bridge.emitMessage(
      const StatusMessage(status: ProcessStatus.idle),
      sessionId: _runtime,
    );
    await pumpEventQueue();
    cubit.updateDetachedProviderStatus(
      _status(
        activity: 'idle',
        runtime: null,
        observedAt: '2026-10-02T11:00:02.000Z',
      ),
      sourceFingerprint: _source,
    );
    expect(streaming.state.isStreaming, isTrue);
    expect(streaming.state.text, 'Final answer');
  });

  test(
    'rejected attachment authority cannot clear a preserved visual turn',
    () async {
      final cubit = createCubit();
      await streamFinal();
      cubit.updateDetachedLiveRuntime('runtime-replacement');
      bridge.emitMessage(
        const StreamDeltaMessage(text: ' continuing same turn'),
        sessionId: 'runtime-replacement',
      );
      await pumpEventQueue();
      cubit.updateDetachedProviderStatus(
        _status(activity: 'idle', observedAt: '2026-10-02T11:00:02.000Z'),
        sourceFingerprint: _source,
      );
      expect(streaming.state.text, 'Final answer');
      expect(
        cubit.diagnosticRuntimeProjection['visualTurnValidationPending'],
        isTrue,
      );
      cubit.updateDetachedProviderStatus(
        _status(
          observedAt: '2026-10-02T11:00:03.000Z',
          authority: 'authority-replacement',
        ),
        sourceFingerprint: _source,
      );
      await pumpEventQueue();
      expect(cubit.state.status, ProcessStatus.running);
      expect(streaming.state.text, 'Final answer continuing same turn');
    },
  );
}
