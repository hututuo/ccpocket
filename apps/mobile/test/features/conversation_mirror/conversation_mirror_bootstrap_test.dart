import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _BootstrapBridge extends BridgeService {
  final _messages = StreamController<ServerMessage>.broadcast();
  var historyRequests = 0;

  void emitForSession(ServerMessage message) => _messages.add(message);

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) =>
      _messages.stream;

  @override
  void requestSessionHistory(String sessionId) {
    historyRequests += 1;
  }

  @override
  void dispose() {
    _messages.close();
    super.dispose();
  }
}

void main() {
  test(
    'local bootstrap renders first and suppresses duplicate full history',
    () async {
      final bridge = _BootstrapBridge();
      final streaming = StreamingStateCubit();
      addTearDown(bridge.dispose);
      addTearDown(streaming.close);

      bridge.configureSessionHistoryBootstrap(({
        required runtimeSessionId,
        required provider,
        required providerSessionId,
        required projectPath,
        required force,
      }) async {
        expect(runtimeSessionId, 'runtime-1');
        expect(provider, 'codex');
        expect(force, isFalse);
        bridge.emitForSession(
          const HistoryMessage(
            messages: [
              UserInputMessage(
                text: 'from phone database',
                userMessageUuid: 'user-1',
              ),
            ],
          ),
        );
        return true;
      });

      final cubit = ChatSessionCubit(
        sessionId: 'runtime-1',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        initialProjectPath: '/tmp/project',
      );
      addTearDown(cubit.close);
      await pumpEventQueue();

      expect(bridge.historyRequests, 0);
      expect(
        cubit.state.entries.whereType<UserChatEntry>().single.text,
        'from phone database',
      );
      expect(
        cubit.state.entries.whereType<UserChatEntry>().single.status,
        MessageStatus.sent,
      );
    },
  );

  test(
    'unsupported or failed bootstrap preserves existing history request',
    () async {
      final bridge = _BootstrapBridge();
      final streaming = StreamingStateCubit();
      addTearDown(bridge.dispose);
      addTearDown(streaming.close);
      bridge.configureSessionHistoryBootstrap(
        ({
          required runtimeSessionId,
          required provider,
          required providerSessionId,
          required projectPath,
          required force,
        }) async => false,
      );

      final cubit = ChatSessionCubit(
        sessionId: 'runtime-1',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
      );
      addTearDown(cubit.close);
      await pumpEventQueue();

      expect(bridge.historyRequests, 1);
    },
  );

  test('manual refresh asks mirror for a forced reconciliation', () async {
    final bridge = _BootstrapBridge();
    final streaming = StreamingStateCubit();
    addTearDown(bridge.dispose);
    addTearDown(streaming.close);
    final forceValues = <bool>[];
    bridge.configureSessionHistoryBootstrap(({
      required runtimeSessionId,
      required provider,
      required providerSessionId,
      required projectPath,
      required force,
    }) async {
      forceValues.add(force);
      return true;
    });

    final cubit = ChatSessionCubit(
      sessionId: 'runtime-1',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
    );
    addTearDown(cubit.close);
    await pumpEventQueue();
    cubit.refreshHistory();
    await pumpEventQueue();

    expect(forceValues, [false, true]);
    expect(bridge.historyRequests, 0);
  });

  test(
    'external snapshots use the chat stream without claiming runtime seq',
    () async {
      final bridge = BridgeService();
      addTearDown(bridge.dispose);
      final received = bridge.messagesForSession('runtime-1').first;

      bridge.publishExternalSessionHistory('runtime-1', const [
        UserInputMessage(text: 'desktop message', userMessageUuid: 'user-1'),
      ]);

      expect(await received, isA<HistoryMessage>());
      expect(
        bridge.cachedSessionMessages('runtime-1').whereType<UserInputMessage>(),
        isEmpty,
      );
      expect(bridge.cachedSessionHistorySeq('runtime-1'), 0);
    },
  );
}
