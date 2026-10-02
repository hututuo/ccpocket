import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_layout.dart';
import 'package:ccpocket/models/messages.dart';
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
  String authority = _authority,
}) => ConversationSyncV2Status(
  provider: provider,
  providerSessionId: thread,
  activity: activity,
  attention: 'none',
  result: 'none',
  runtimeAttachment: 'loaded',
  source: 'bridgeRuntime',
  confidence: 'authoritative',
  observedAt: observedAt,
  executionHost: 'bridge',
  activeTurnId: activity == 'working' ? _turn : null,
  controlState: activity == 'working' ? 'steerable' : 'writable',
  authorityGeneration: authority,
);

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

  ChatSessionCubit createCubit() {
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
    cubit.updateDetachedProviderStatus(_status(), sourceFingerprint: _source);
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
