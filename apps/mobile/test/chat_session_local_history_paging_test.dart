import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final _taggedController =
      StreamController<(ServerMessage, String?)>.broadcast();
  final _connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final _localFeatureController =
      StreamController<(LocalFeatureServerMessage, String)>.broadcast();
  final sentMessages = <ClientMessage>[];

  List<SessionInfo> sessionSnapshot = const [];
  int requestSessionHistoryCallCount = 0;

  @override
  bool get isConnected => true;

  @override
  List<SessionInfo> get sessions => sessionSnapshot;

  @override
  Set<String> get bridgeCapabilities => const {};

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _connectionController.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => const Stream.empty();

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) =>
      _taggedController.stream
          .where((pair) => pair.$2 == null || pair.$2 == sessionId)
          .map((pair) => pair.$1);

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => _localFeatureController.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  void publishExternalSessionHistory(
    String runtimeSessionId,
    List<ServerMessage> messages, {
    DateTime? timestampAnchor,
  }) {
    emitMessage(
      buildExternalSessionHistory(messages, timestampAnchor: timestampAnchor),
      sessionId: runtimeSessionId,
    );
  }

  void emitMessage(ServerMessage message, {String? sessionId}) {
    _taggedController.add((message, sessionId));
  }

  @override
  void send(ClientMessage message) => sentMessages.add(message);

  @override
  void requestSessionHistory(String sessionId) {
    requestSessionHistoryCallCount += 1;
  }

  @override
  void requestSessionList() {}

  @override
  void requestFileList(String projectPath) {}

  @override
  void interrupt(String sessionId) {}

  @override
  void stopSession(String sessionId) {}

  @override
  void dispose() {
    _taggedController.close();
    _connectionController.close();
    _localFeatureController.close();
    super.dispose();
  }
}

void main() {
  late _Bridge bridge;
  late StreamingStateCubit streamingCubit;
  late List<ChatSessionCubit> cubits;

  setUp(() {
    bridge = _Bridge();
    streamingCubit = StreamingStateCubit();
    cubits = [];
  });

  tearDown(() async {
    for (final cubit in cubits.reversed) {
      await cubit.close();
    }
    await streamingCubit.close();
    bridge.dispose();
  });

  ChatSessionCubit createCubit() {
    final cubit = ChatSessionCubit(
      sessionId: 's1',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streamingCubit,
    );
    cubits.add(cubit);
    return cubit;
  }

  Future<void> settleBootstrap() async {
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});
  }

  test(
    'local mirror pages older history without blocking a live append',
    () async {
      final pageGate = Completer<void>();
      var hasMore = true;
      bridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
        ),
      ];
      bridge.configureSessionHistoryBootstrap(({
        required runtimeSessionId,
        required provider,
        required providerSessionId,
        required projectPath,
        required force,
      }) async {
        bridge.publishExternalSessionHistory(runtimeSessionId, const [
          UserInputMessage(text: 'recent-tail', userMessageUuid: 'tail-user'),
        ]);
        return true;
      });
      bridge.configureSessionHistoryPaging(
        hasMore: (_) => hasMore,
        loader: ({required runtimeSessionId, required limit}) async {
          await pageGate.future;
          hasMore = false;
          return const LocalSessionHistoryPage(
            messages: [
              UserInputMessage(
                text: 'older-page',
                userMessageUuid: 'older-user',
              ),
            ],
            hasMore: false,
          );
        },
      );

      final cubit = createCubit();
      await settleBootstrap();

      expect(cubit.state.status, ProcessStatus.idle);
      expect(
        cubit.state.entries.whereType<UserChatEntry>().single.text,
        'recent-tail',
      );
      expect(cubit.localHistoryPaging.value.hasMore, isTrue);

      final load = cubit.loadOlderLocalHistory();
      bridge.emitMessage(
        const AssistantServerMessage(
          message: AssistantMessage(
            id: 'live-assistant',
            role: 'assistant',
            content: [TextContent(text: 'live-append')],
            model: 'codex',
          ),
        ),
        sessionId: 's1',
      );
      await Future<void>.microtask(() {});
      pageGate.complete();
      await load;

      expect(
        cubit.state.entries.map(
          (entry) => switch (entry) {
            UserChatEntry(:final text) => text,
            ServerChatEntry(message: AssistantServerMessage(:final message)) =>
              (message.content.single as TextContent).text,
            _ => 'other',
          },
        ),
        ['older-page', 'recent-tail', 'live-append'],
      );
      expect(cubit.localHistoryPaging.value.hasMore, isFalse);
      expect(bridge.requestSessionHistoryCallCount, 0);

      bridge.emitMessage(
        const HistoryMessage(
          messages: [
            UserInputMessage(text: 'older-page', userMessageUuid: 'older-user'),
            UserInputMessage(text: 'recent-tail', userMessageUuid: 'tail-user'),
            AssistantServerMessage(
              message: AssistantMessage(
                id: 'live-assistant',
                role: 'assistant',
                content: [TextContent(text: 'live-append')],
                model: 'codex',
              ),
            ),
          ],
        ),
        sessionId: 's1',
      );
      await Future<void>.microtask(() {});
      expect(cubit.state.entries, hasLength(3));
    },
  );

  test(
    'canonical history invalidates an in-flight local mirror page',
    () async {
      final pageGate = Completer<void>();
      var hasMore = true;
      var invalidated = false;
      bridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
        ),
      ];
      bridge.configureSessionHistoryBootstrap(({
        required runtimeSessionId,
        required provider,
        required providerSessionId,
        required projectPath,
        required force,
      }) async {
        bridge.publishExternalSessionHistory(runtimeSessionId, const [
          UserInputMessage(
            text: 'mirror-tail',
            userMessageUuid: 'mirror-tail-user',
          ),
        ]);
        return true;
      });
      bridge.configureSessionHistoryPaging(
        hasMore: (_) => hasMore,
        invalidate: (_) {
          invalidated = true;
          hasMore = false;
        },
        loader: ({required runtimeSessionId, required limit}) async {
          await pageGate.future;
          return const LocalSessionHistoryPage(
            messages: [
              UserInputMessage(
                text: 'stale-older-page',
                userMessageUuid: 'stale-older-user',
              ),
            ],
            hasMore: true,
          );
        },
      );

      final cubit = createCubit();
      await settleBootstrap();
      expect(cubit.localHistoryPaging.value.hasMore, isTrue);

      final load = cubit.loadOlderLocalHistory();
      bridge.emitMessage(
        const HistoryMessage(
          messages: [
            UserInputMessage(
              text: 'canonical-history',
              userMessageUuid: 'canonical-user',
            ),
          ],
        ),
        sessionId: 's1',
      );
      await Future<void>.microtask(() {});
      pageGate.complete();
      await load;

      expect(invalidated, isTrue);
      expect(cubit.localHistoryPaging.value.enabled, isFalse);
      expect(
        cubit.state.entries.whereType<UserChatEntry>().map(
          (entry) => entry.text,
        ),
        ['canonical-history'],
      );
    },
  );

  test(
    'waiting mirror restores approval and reconciles canonical runtime',
    () async {
      const pending = PermissionRequestMessage(
        toolUseId: 'tool-1',
        toolName: 'Bash',
        input: {'command': 'pwd'},
      );
      bridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'waiting_approval',
          createdAt: '',
          lastActivityAt: '',
          pendingPermission: pending,
        ),
      ];
      bridge.configureSessionHistoryBootstrap(({
        required runtimeSessionId,
        required provider,
        required providerSessionId,
        required projectPath,
        required force,
      }) async {
        bridge.publishExternalSessionHistory(runtimeSessionId, const [
          UserInputMessage(text: 'recent-tail', userMessageUuid: 'tail-user'),
        ]);
        return true;
      });

      final cubit = createCubit();
      await settleBootstrap();

      expect(cubit.state.status, ProcessStatus.waitingApproval);
      final approval = cubit.state.approval as ApprovalPermission;
      expect(approval.toolUseId, 'tool-1');
      expect(approval.request.toolName, 'Bash');
      expect(bridge.requestSessionHistoryCallCount, 1);
    },
  );

  test(
    'running mirror restores queue before accepting another input',
    () async {
      const queued = QueuedInputItem(
        itemId: 'queue-1',
        text: 'already queued',
        createdAt: '2026-07-20T00:00:00Z',
      );
      bridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'running',
          createdAt: '',
          lastActivityAt: '',
          queuedInput: queued,
        ),
      ];
      bridge.configureSessionHistoryBootstrap(({
        required runtimeSessionId,
        required provider,
        required providerSessionId,
        required projectPath,
        required force,
      }) async {
        bridge.publishExternalSessionHistory(runtimeSessionId, const [
          UserInputMessage(text: 'recent-tail', userMessageUuid: 'tail-user'),
        ]);
        return true;
      });

      final cubit = createCubit();
      await settleBootstrap();

      expect(cubit.state.status, ProcessStatus.running);
      expect(cubit.state.queuedInput?.itemId, 'queue-1');
      expect(bridge.requestSessionHistoryCallCount, 1);

      cubit.sendMessage('must not create a second queue item');
      expect(bridge.sentMessages, isEmpty);
    },
  );
}
