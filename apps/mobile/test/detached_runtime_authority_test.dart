import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_session_cubit_test.dart' show MockBridgeService;

const _thread = 'durable-authority-thread';
const _runtimeA = 'runtime-authority-a';
const _runtimeB = 'runtime-authority-b';
const _runtimeC = 'runtime-authority-c';
const _source = 'bridge-a/source-a';
const _authorityC = 'authority-current-c';

ConversationSyncV2Status _status({
  String? runtime = _runtimeC,
  String? authority = _authorityC,
  String control = 'writable',
  String source = 'bridgeRuntime',
  String host = 'bridge',
  String observedAt = '2026-10-03T00:00:02.000Z',
}) => ConversationSyncV2Status.fromJson(
  ConversationSyncV2Status(
    provider: 'codex',
    providerSessionId: _thread,
    activity: control == 'writable' ? 'idle' : 'working',
    attention: 'none',
    result: 'none',
    runtimeAttachment: 'loaded',
    source: source,
    confidence: 'authoritative',
    observedAt: observedAt,
    executionHost: host,
    activeTurnId: control == 'writable' ? null : 'turn-authority-current',
    controlState: control,
    authorityGeneration: authority,
    runtimeSessionId: runtime,
  ).toJson(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockBridgeService bridge;
  late StreamingStateCubit streaming;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = MockBridgeService();
    streaming = StreamingStateCubit();
  });

  tearDown(() async {
    await streaming.close();
    bridge.dispose();
  });

  ChatSessionCubit create({
    String? runtime = _runtimeC,
    ChatImagePayloadEncoder? imagePayloadEncoder,
  }) {
    final cubit = ChatSessionCubit(
      sessionId: _thread,
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
      initialLiveRuntimeSessionId: runtime,
      imagePayloadEncoder: imagePayloadEncoder,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  void apply(ChatSessionCubit cubit, ConversationSyncV2Status status) {
    cubit.updateDetachedProviderStatus(status, sourceFingerprint: _source);
  }

  ChatSessionCubit replacePastUnobservedB() {
    final cubit = create(runtime: _runtimeA);
    apply(
      cubit,
      _status(
        runtime: _runtimeA,
        authority: 'authority-initial-a',
        observedAt: '2026-10-03T00:00:00.000Z',
      ),
    );
    expect(cubit.canMutateAttachedRuntime, isTrue);
    cubit.updateDetachedLiveRuntime(_runtimeB);
    // No B status was observed before the second replacement.
    cubit.updateDetachedLiveRuntime(_runtimeC);
    expect(cubit.canMutateAttachedRuntime, isFalse);
    expect(cubit.runtimeSessionIdForRead, _runtimeC);
    return cubit;
  }

  void controls(ChatSessionCubit cubit) {
    cubit.approve('approval-current');
    cubit.approveAlways('always-current');
    cubit.reject('rejection-current');
    cubit.answer('question-current', 'Continue');
    cubit.interrupt();
    cubit.stop();
  }

  List<Map<String, dynamic>> sentPayloads() => bridge.sentMessages
      .map((message) => jsonDecode(message.toJson()) as Map<String, dynamic>)
      .toList();

  for (final overlays in [false, true]) {
    group(overlays ? 'V2 with overlays' : 'V2 without overlays', () {
      setUp(() {
        bridge.advertisedBridgeCapabilities = {
          conversationSyncV2Capability,
          if (overlays) conversationRuntimeOverlayCapability,
        };
      });

      for (final control in ['writable', 'steerable']) {
        test('unobserved B $control cannot dispatch input to C', () async {
          final cubit = replacePastUnobservedB();
          apply(
            cubit,
            _status(
              runtime: _runtimeB,
              authority: 'authority-unobserved-b',
              control: control,
            ),
          );

          final accepted = cubit.sendMessage(
            'Must not write using B authority',
          );
          await pumpEventQueue();
          expect(sentPayloads(), isEmpty);
          expect(accepted, isFalse);
          expect(cubit.canMutateAttachedRuntime, isFalse);
          expect(cubit.runtimeSessionIdForMutation(), isNull);
          expect(cubit.runtimeSessionIdForRead, _runtimeC);
        });
      }

      test('unobserved B cannot approve, answer, interrupt or stop C', () {
        final cubit = replacePastUnobservedB();
        apply(
          cubit,
          _status(runtime: _runtimeB, authority: 'authority-unobserved-b'),
        );
        controls(cubit);

        expect(sentPayloads(), isEmpty);
        expect(bridge.interruptedSessionIds, isEmpty);
        expect(bridge.stoppedSessionIds, isEmpty);
        expect(cubit.canMutateAttachedRuntime, isFalse);
      });

      for (final action in ['interrupt', 'stop']) {
        test('unobserved B cannot $action the bound C process', () {
          final cubit = replacePastUnobservedB();
          apply(
            cubit,
            _status(runtime: _runtimeB, authority: 'authority-unobserved-b'),
          );
          if (action == 'interrupt') {
            cubit.interrupt();
            expect(bridge.interruptedSessionIds, isEmpty);
          } else {
            cubit.stop();
            expect(bridge.stoppedSessionIds, isEmpty);
          }
          expect(sentPayloads(), isEmpty);
          expect(cubit.canMutateAttachedRuntime, isFalse);
        });
      }

      test('unobserved B cannot create a mixed C settings target', () {
        final cubit = replacePastUnobservedB();
        apply(
          cubit,
          _status(runtime: _runtimeB, authority: 'authority-unobserved-b'),
        );
        cubit.setCodexModel(
          'gpt-5.4-mini',
          reasoningEffort: ReasoningEffort.low,
        );

        expect(sentPayloads(), isEmpty);
        expect(
          cubit.codexSettingsActionability,
          isNot(CodexSettingsActionability.editable),
        );
      });

      test('matching C identity without authority grants no mutation', () {
        final cubit = create();
        apply(cubit, _status(authority: null));
        expect(cubit.sendMessage('Identity alone is insufficient'), isFalse);
        controls(cubit);
        cubit.setCodexModel(
          'gpt-5.4-mini',
          reasoningEffort: ReasoningEffort.low,
        );

        expect(bridge.sentMessages, isEmpty);
        expect(bridge.interruptedSessionIds, isEmpty);
        expect(bridge.stoppedSessionIds, isEmpty);
        expect(cubit.canMutateAttachedRuntime, isFalse);
      });

      test(
        'unbound status stays readable without granting runtime control',
        () {
          final cubit = create(runtime: null);
          final status = _status(control: 'steerable');
          apply(cubit, status);

          expect(cubit.state.status, ProcessStatus.running);
          expect(cubit.runtimeSessionIdForRead, isNull);
          expect(cubit.canMutateAttachedRuntime, isFalse);
          expect(cubit.sendMessage('No bound runtime'), isFalse);
          expect(sentPayloads(), isEmpty);

          cubit.updateDetachedLiveRuntime(_runtimeC);
          expect(cubit.canMutateAttachedRuntime, isFalse);
          // The original updater replays its committed status after binding.
          apply(cubit, status);
          expect(cubit.state.status, ProcessStatus.running);
          expect(cubit.runtimeSessionIdForMutation(), _runtimeC);
        },
      );

      test('late B cannot replace the already proven C settings owner', () {
        final cubit = create();
        apply(cubit, _status(observedAt: '2026-10-03T00:00:01.000Z'));
        apply(
          cubit,
          _status(runtime: _runtimeB, authority: 'authority-unobserved-b'),
        );
        cubit.setCodexModel(
          'gpt-5.4-mini',
          reasoningEffort: ReasoningEffort.low,
        );

        final settings = sentPayloads().single;
        expect(settings['runtimeSessionId'], _runtimeC);
        expect(settings['authorityGeneration'], _authorityC);
        expect(cubit.canMutateAttachedRuntime, isTrue);
      });

      test('late B cannot cancel a valid C image dispatch lease', () async {
        final encoded = Completer<List<Map<String, String>>>();
        final cubit = create(imagePayloadEncoder: (_) => encoded.future);
        apply(cubit, _status(observedAt: '2026-10-03T00:00:01.000Z'));
        expect(
          cubit.sendMessage(
            'Image for the current owner',
            images: [
              (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
            ],
          ),
          isTrue,
        );
        await Future<void>.microtask(() {});
        expect(sentPayloads(), isEmpty);
        apply(
          cubit,
          _status(runtime: _runtimeB, authority: 'authority-unobserved-b'),
        );
        encoded.complete(const [
          {'base64': 'AQID', 'mimeType': 'image/png'},
        ]);
        await pumpEventQueue();

        expect(sentPayloads(), hasLength(1));
        final input = sentPayloads().single;
        expect(input['type'], 'input');
        expect(input['sessionId'], _runtimeC);
        expect(cubit.canMutateAttachedRuntime, isTrue);
      });

      test(
        'current C authority restores public mutations after stale B',
        () async {
          final cubit = replacePastUnobservedB();
          apply(
            cubit,
            _status(runtime: _runtimeB, authority: 'authority-unobserved-b'),
          );
          // Equal observation time still permits the actual current identity.
          apply(cubit, _status());
          expect(cubit.canMutateAttachedRuntime, isTrue);
          expect(cubit.runtimeSessionIdForMutation(), _runtimeC);
          expect(cubit.sendMessage('Current runtime input'), isTrue);
          await pumpEventQueue();
          controls(cubit);
          cubit.setCodexModel(
            'gpt-5.4-mini',
            reasoningEffort: ReasoningEffort.low,
          );

          final payloads = bridge.sentMessages
              .map(
                (message) =>
                    jsonDecode(message.toJson()) as Map<String, dynamic>,
              )
              .toList();
          expect(payloads, hasLength(6));
          expect(payloads.map((p) => p['sessionId']), everyElement(_runtimeC));
          final settings = payloads.singleWhere(
            (p) => p['type'] == 'set_codex_model',
          );
          expect(settings['threadId'], _thread);
          expect(settings['codexSourceId'], 'source-a');
          expect(settings['runtimeSessionId'], _runtimeC);
          expect(settings['authorityGeneration'], _authorityC);
          expect(settings['operationId'], isNotEmpty);
          expect(bridge.interruptedSessionIds, [_runtimeC]);
          expect(bridge.stoppedSessionIds, [_runtimeC]);
        },
      );
    });
  }

  test(
    'older V2 status without runtime identity keeps its existing lease',
    () async {
      bridge.advertisedBridgeCapabilities = {conversationSyncV2Capability};
      final cubit = create();
      apply(cubit, _status(runtime: null));
      expect(cubit.sendMessage('Compatible V2 input'), isTrue);
      await pumpEventQueue();
      expect(
        jsonDecode(bridge.sentMessages.single.toJson())['sessionId'],
        _runtimeC,
      );
    },
  );

  test(
    'legacy idle attachment retains its existing no-status fallback',
    () async {
      final cubit = create();
      expect(cubit.sendMessage('Compatible legacy input'), isTrue);
      await pumpEventQueue();
      expect(
        jsonDecode(bridge.sentMessages.single.toJson())['sessionId'],
        _runtimeC,
      );
    },
  );

  test(
    'Desktop authority without Bridge identity retains detach semantics',
    () {
      bridge.advertisedBridgeCapabilities = {
        conversationSyncV2Capability,
        codexRuntimeDetachCapability,
      };
      final cubit = create();
      apply(
        cubit,
        _status(
          runtime: null,
          control: 'readOnly',
          source: 'appServer',
          host: 'desktopAppServer',
        ),
      );
      expect(cubit.canMutateAttachedRuntime, isFalse);
      expect(cubit.stopActionDetachesDesktopTurn, isTrue);
      cubit.stop();
      final payload = jsonDecode(bridge.sentMessages.single.toJson());
      expect(payload['type'], 'detach_session');
      expect(payload['sessionId'], _runtimeC);
      expect(payload['threadId'], _thread);
      expect(payload['authorityGeneration'], _authorityC);
      expect(bridge.stoppedSessionIds, isEmpty);
      expect(bridge.interruptedSessionIds, isEmpty);
    },
  );

  test('durable settings remain independent of a runtime mutation lease', () {
    bridge.advertisedBridgeCapabilities = {
      conversationSyncV2Capability,
      codexDurableThreadSettingsCapability,
    };
    final cubit = replacePastUnobservedB();
    apply(
      cubit,
      _status(runtime: _runtimeB, authority: 'authority-unobserved-b'),
    );
    cubit.setCodexModel('gpt-5.4-mini', reasoningEffort: ReasoningEffort.low);
    final payload = jsonDecode(bridge.sentMessages.single.toJson());
    expect(payload['type'], 'set_codex_model');
    expect(payload['threadId'], _thread);
    expect(payload['codexSourceId'], 'source-a');
    expect(payload['runtimeSessionId'], isNull);
    expect(payload['authorityGeneration'], isNull);
  });
}
