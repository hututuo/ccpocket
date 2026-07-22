import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

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
    'canonical history coexists with an in-flight local mirror page',
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

      expect(invalidated, isFalse);
      expect(cubit.localHistoryPaging.value.enabled, isTrue);
      expect(cubit.localHistoryPaging.value.hasMore, isTrue);
      expect(
        cubit.state.entries.whereType<UserChatEntry>().map(
          (entry) => entry.text,
        ),
        ['stale-older-page', 'mirror-tail', 'canonical-history'],
      );
    },
  );

  test(
    'canonical overlap updates the mirror tail without appending older prefix',
    () async {
      var invalidated = false;
      bridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'running',
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
            text: 'mirror tail before canonical',
            userMessageUuid: 'shared-user',
          ),
        ]);
        return true;
      });
      bridge.configureSessionHistoryPaging(
        hasMore: (_) => true,
        invalidate: (_) => invalidated = true,
        loader: ({required runtimeSessionId, required limit}) async {
          return const LocalSessionHistoryPage(messages: [], hasMore: true);
        },
      );

      final cubit = createCubit();
      await settleBootstrap();
      expect(cubit.localHistoryPaging.value.enabled, isTrue);

      bridge.emitMessage(
        const HistoryMessage(
          messages: [
            UserInputMessage(
              text: 'canonical older prefix',
              userMessageUuid: 'older-user',
            ),
            UserInputMessage(
              text: 'canonical tail wins',
              userMessageUuid: 'shared-user',
            ),
            AssistantServerMessage(
              message: AssistantMessage(
                id: 'canonical-live-assistant',
                role: 'assistant',
                content: [TextContent(text: 'new live answer')],
                model: 'codex',
              ),
              messageUuid: 'canonical-live-assistant-uuid',
            ),
          ],
        ),
        sessionId: 's1',
      );
      await Future<void>.microtask(() {});

      expect(invalidated, isFalse);
      expect(cubit.localHistoryPaging.value.enabled, isTrue);
      expect(
        cubit.state.entries.whereType<UserChatEntry>().map(
          (entry) => entry.text,
        ),
        ['canonical tail wins'],
      );
      expect(
        cubit.state.entries.whereType<ServerChatEntry>().where((entry) {
          return entry.message is AssistantServerMessage;
        }),
        hasLength(1),
      );
    },
  );

  test('full prompt index reveals an unloaded turn by paging to it', () async {
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
        UserInputMessage(
          text: 'recent visible prompt',
          userMessageUuid: 'recent-user',
        ),
      ]);
      return true;
    });
    bridge.configureSessionHistoryPaging(
      hasMore: (_) => hasMore,
      loader: ({required runtimeSessionId, required limit}) async {
        hasMore = false;
        return const LocalSessionHistoryPage(
          messages: [
            UserInputMessage(
              text: 'old unloaded prompt',
              userMessageUuid: 'old-user',
            ),
          ],
          hasMore: false,
        );
      },
    );
    bridge.configureSessionHistoryUserIndex(({
      required runtimeSessionId,
    }) async {
      return const [
        UserInputMessage(
          text: 'old unloaded prompt',
          userMessageUuid: 'old-user',
        ),
        UserInputMessage(
          text: 'recent visible prompt',
          userMessageUuid: 'recent-user',
        ),
      ];
    });

    final cubit = createCubit();
    await settleBootstrap();
    final index = await cubit.loadAllUserMessagesForNavigation();
    expect(index.map((entry) => entry.text), [
      'old unloaded prompt',
      'recent visible prompt',
    ]);
    expect(cubit.state.entries.whereType<UserChatEntry>(), hasLength(1));

    final revealed = await cubit.revealUserMessage(index.first);

    expect(revealed?.messageUuid, 'old-user');
    expect(
      cubit.state.entries.whereType<UserChatEntry>().map((entry) {
        return entry.text;
      }),
      ['old unloaded prompt', 'recent visible prompt'],
    );
    expect(cubit.localHistoryPaging.value.hasMore, isFalse);
  });

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

  testWidgets('ordinary history drag requests the next local page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var hasMore = true;
    var pageCalls = 0;
    final recent = <ServerMessage>[];
    for (var index = 0; index < 36; index++) {
      recent
        ..add(
          UserInputMessage(
            text: 'recent prompt $index ${'content ' * 8}',
            userMessageUuid: 'recent-user-$index',
          ),
        )
        ..add(
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'recent-assistant-$index',
              role: 'assistant',
              content: [
                TextContent(text: 'recent answer $index ${'detail ' * 10}'),
              ],
              model: 'codex',
            ),
          ),
        );
    }
    bridge.configureSessionHistoryBootstrap(({
      required runtimeSessionId,
      required provider,
      required providerSessionId,
      required projectPath,
      required force,
    }) async {
      bridge.publishExternalSessionHistory(runtimeSessionId, recent);
      return true;
    });
    bridge.configureSessionHistoryPaging(
      hasMore: (_) => hasMore,
      loader: ({required runtimeSessionId, required limit}) async {
        pageCalls += 1;
        hasMore = false;
        return const LocalSessionHistoryPage(
          messages: [
            UserInputMessage(
              text: 'oldest loaded by scroll',
              userMessageUuid: 'oldest-user',
            ),
          ],
          hasMore: false,
        );
      },
    );

    final cubit = createCubit();
    final scrollController = AutoScrollController();
    addTearDown(scrollController.dispose);
    await tester.pumpWidget(
      RepositoryProvider<BridgeService>.value(
        value: bridge,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ChatSessionCubit>.value(value: cubit),
            BlocProvider<StreamingStateCubit>.value(value: streamingCubit),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: ChatMessageList(
                sessionId: 's1',
                scrollController: scrollController,
                httpBaseUrl: null,
                onRetryMessage: null,
                collapseToolResults: null,
                isCodex: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(cubit.localHistoryPaging.value.hasMore, isTrue);
    expect(pageCalls, 0);
    expect(scrollController.position.maxScrollExtent, greaterThan(0));

    await tester.drag(find.byType(ListView), const Offset(0, 20000));
    await tester.pump();

    expect(
      scrollController.offset,
      greaterThanOrEqualTo(scrollController.position.maxScrollExtent - 480),
    );
    await tester.pumpAndSettle();

    expect(pageCalls, 1);
    expect(
      cubit.state.entries.whereType<UserChatEntry>().first.text,
      'oldest loaded by scroll',
    );
    expect(cubit.localHistoryPaging.value.hasMore, isFalse);
    expect(tester.takeException(), isNull);

    cubits.remove(cubit);
    await cubit.close();
  });
}
