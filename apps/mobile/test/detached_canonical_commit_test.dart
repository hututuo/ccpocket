import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_session_cubit_test.dart' show MockBridgeService;

const _thread = 'durable-canonical-admission';
const _user = UserInputMessage(
  text: 'Read the committed conversation',
  clientMessageId: 'client-last-good',
  providerItemId: 'user-last-good',
  historyTurnId: 'turn-last-good',
);
const _assistant = AssistantServerMessage(
  message: AssistantMessage(
    id: 'assistant-last-good',
    role: 'assistant',
    content: [TextContent(text: 'Last readable reply')],
    model: 'gpt-test',
  ),
  messageUuid: 'assistant-last-good',
  historyTurnId: 'turn-last-good',
);
const _metadata = SystemMessage(
  subtype: 'init',
  provider: 'codex',
  claudeSessionId: _thread,
  projectPath: '/last-good-project',
  model: 'gpt-last-good',
);
const _gitTip = SystemMessage(subtype: 'tip', tipCode: 'git_not_available');
const _gitError = ErrorMessage(
  message: 'Git is unavailable for this project',
  errorCode: 'git_not_available',
  sessionId: _thread,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockBridgeService bridge;
  late StreamingStateCubit streaming;

  setUp(() {
    bridge = MockBridgeService()
      ..advertisedBridgeCapabilities = const {conversationSyncV2Capability};
    streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
  });
  tearDown(() {
    streaming.close();
    bridge.dispose();
  });

  ChatSessionCubit createCubit({
    DraftService? drafts,
    List<ServerMessage> initial = const [_metadata, _user, _assistant],
    DetachedHistoryPageLoader? pageLoader,
    bool hasEarlier = false,
  }) {
    final cubit = ChatSessionCubit(
      sessionId: _thread,
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
      initialHistoryMessages: initial,
      outgoingDrafts: drafts,
      detachedHistoryPageLoader: pageLoader,
      initialHistoryHasEarlier: hasEarlier,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Map<String, Object?> projection(ChatSessionCubit cubit) =>
      cubit.diagnosticRuntimeProjection['timelineProjection']!
          as Map<String, Object?>;

  void expectRejectedLastGood(ChatSessionCubit cubit) {
    expect(projection(cubit)['lastAction'], 'canonical_rejected_duplicate');
    expect(projection(cubit)['duplicateCanonicalCount'], 1);
    expect(
      cubit.visibleEntries
          .whereType<ServerChatEntry>()
          .map((entry) => entry.message)
          .whereType<AssistantServerMessage>()
          .map((message) => message.message.id),
      ['assistant-last-good'],
    );
  }

  test('rejected canonical candidate cannot replace last-good metadata', () {
    final cubit = createCubit();
    expect(cubit.state.projectPath, '/last-good-project');
    expect(cubit.state.codexModel, 'gpt-last-good');

    cubit.updateDetachedPreviewHistory(const [
      SystemMessage(
        subtype: 'init',
        provider: 'codex',
        claudeSessionId: _thread,
        projectPath: '/rejected-project',
        model: 'gpt-rejected',
      ),
      _user,
      _assistant,
      _assistant,
    ]);

    expectRejectedLastGood(cubit);
    expect(cubit.state.projectPath, '/last-good-project');
    expect(cubit.state.codexModel, 'gpt-last-good');
  });

  test('rejected canonical candidate cannot introduce an approval', () {
    final cubit = createCubit();
    expect(cubit.state.approval, const ApprovalState.none());

    cubit.updateDetachedPreviewHistory(const [
      StatusMessage(status: ProcessStatus.waitingApproval),
      PermissionRequestMessage(
        toolUseId: 'approval-from-rejected-candidate',
        toolName: 'Bash',
        input: {'command': 'fixture command'},
      ),
      _user,
      _assistant,
      _assistant,
    ]);

    expectRejectedLastGood(cubit);
    expect(cubit.state.approval, const ApprovalState.none());
    expect(cubit.state.status, ProcessStatus.idle);
  });

  test('rejected canonical candidate cannot replace the last-good queue', () {
    const retainedQueue = ConversationQueueMessage(
      limit: 3,
      items: [
        QueuedInputItem(
          itemId: 'queue-last-good',
          clientMessageId: 'queue-client-last-good',
          text: 'Retained queue',
          createdAt: '2026-10-02T06:00:00.000Z',
        ),
      ],
    );
    final cubit = createCubit(
      initial: const [_metadata, _user, _assistant, retainedQueue],
    );
    expect(cubit.queuedInputs.value.single.itemId, 'queue-last-good');

    cubit.updateDetachedPreviewHistory(const [
      ConversationQueueMessage(limit: 1, items: []),
      _user,
      _assistant,
      _assistant,
    ]);

    expectRejectedLastGood(cubit);
    expect(cubit.queuedInputs.value.map((item) => item.itemId), [
      'queue-last-good',
    ]);
    expect(cubit.queuedInputLimit, 3);
  });

  test('rejected canonical candidate cannot change paging availability', () {
    final cubit = createCubit(
      pageLoader: () async => (loaded: true, hasMore: false),
      hasEarlier: true,
    );
    expect(cubit.localHistoryPaging.value.enabled, isTrue);
    expect(cubit.localHistoryPaging.value.hasMore, isTrue);

    cubit.updateDetachedPreviewHistory(const [
      _user,
      _assistant,
      _assistant,
    ], hasEarlier: false);

    expectRejectedLastGood(cubit);
    expect(cubit.localHistoryPaging.value.hasMore, isTrue);
    cubit.updateDetachedPreviewHistory(const [
      _user,
      _assistant,
    ], hasEarlier: false);
    expect(cubit.localHistoryPaging.value.hasMore, isFalse);
  });

  test('rejected history cannot suppress a later valid git error', () async {
    final cubit = createCubit();
    cubit.updateDetachedPreviewHistory(const [
      _gitTip,
      _user,
      _assistant,
      _assistant,
    ]);
    expectRejectedLastGood(cubit);
    expect(
      cubit.visibleEntries.whereType<ServerChatEntry>().any(
        (entry) => entry.message == _gitTip,
      ),
      isFalse,
    );

    bridge.emitMessage(_gitError, sessionId: _thread);
    await pumpEventQueue();
    expect(
      cubit.visibleEntries.whereType<ServerChatEntry>().map(
        (entry) => entry.message,
      ),
      contains(_gitError),
    );
  });

  test('accepted git tip remains acknowledged after a rejection', () async {
    final cubit = createCubit();
    cubit.updateDetachedPreviewHistory(const [_gitTip, _user, _assistant]);
    expect(
      cubit.visibleEntries.whereType<ServerChatEntry>().any(
        (entry) => entry.message == _gitTip,
      ),
      isTrue,
    );
    cubit.updateDetachedPreviewHistory(const [_user, _assistant, _assistant]);
    expectRejectedLastGood(cubit);

    bridge.emitMessage(_gitError, sessionId: _thread);
    await pumpEventQueue();
    expect(
      cubit.visibleEntries.whereType<ServerChatEntry>().map(
        (entry) => entry.message,
      ),
      isNot(contains(_gitError)),
    );
  });

  test(
    'rejection preserves an outgoing draft until a valid exact commit',
    () async {
      SharedPreferences.setMockInitialValues({});
      final drafts = DraftService(await SharedPreferences.getInstance());
      const client = 'client-pending-admission';
      await drafts.savePendingSubmission(
        _thread,
        PendingChatSubmissionDraft(
          clientMessageId: client,
          text: 'Pending input',
        ),
      );
      final cubit = createCubit(drafts: drafts);
      expect(
        cubit.restoreFailedSubmission('Pending input', clientMessageId: client),
        isTrue,
      );
      const committedUser = UserInputMessage(
        text: 'Pending input',
        clientMessageId: client,
        providerItemId: 'provider-pending-admission',
        historyTurnId: 'turn-pending-admission',
      );

      cubit.updateDetachedPreviewHistory(const [
        _user,
        _assistant,
        _assistant,
        committedUser,
      ]);
      expectRejectedLastGood(cubit);
      expect(drafts.getPendingSubmission(_thread)?.clientMessageId, client);
      expect(projection(cubit)['localOutgoingClientIdCount'], 1);
      expect(
        cubit.visibleEntries.whereType<UserChatEntry>().last.status,
        MessageStatus.failed,
      );

      cubit.updateDetachedPreviewHistory(const [
        _user,
        _assistant,
        committedUser,
      ]);
      expect(projection(cubit)['lastAction'], 'canonical_commit');
      expect(drafts.getPendingSubmission(_thread), isNull);
      expect(projection(cubit)['localOutgoingClientIdCount'], 0);
      final committed = cubit.visibleEntries.whereType<UserChatEntry>().last;
      expect(committed.providerItemId, 'provider-pending-admission');
      expect(committed.status, MessageStatus.sent);
      cubit.updateDetachedPreviewHistory(const [
        _user,
        _assistant,
        committedUser,
      ]);
      expect(cubit.visibleEntries.whereType<UserChatEntry>(), hasLength(2));
      expect(drafts.getPendingSubmission(_thread), isNull);
    },
  );

  test(
    'same text with distinct client identities cannot consume another draft',
    () async {
      SharedPreferences.setMockInitialValues({});
      final drafts = DraftService(await SharedPreferences.getInstance());
      await drafts.savePendingSubmission(
        _thread,
        PendingChatSubmissionDraft(
          clientMessageId: 'client-uncommitted',
          text: 'Repeated input',
        ),
      );
      final cubit = createCubit(drafts: drafts);
      expect(
        cubit.restoreFailedSubmission(
          'Repeated input',
          clientMessageId: 'client-uncommitted',
        ),
        isTrue,
      );
      const anotherUser = UserInputMessage(
        text: 'Repeated input',
        clientMessageId: 'client-another',
        providerItemId: 'provider-another',
        historyTurnId: 'turn-another',
      );

      for (var replay = 0; replay < 2; replay++) {
        cubit.updateDetachedPreviewHistory(const [
          _user,
          _assistant,
          anotherUser,
        ]);
        expect(
          cubit.visibleEntries.whereType<UserChatEntry>().map(
            (entry) => entry.clientMessageId,
          ),
          ['client-last-good', 'client-another', 'client-uncommitted'],
        );
        expect(
          drafts.getPendingSubmission(_thread)?.clientMessageId,
          'client-uncommitted',
        );
        expect(projection(cubit)['localOutgoingClientIdCount'], 1);
      }
    },
  );
}
