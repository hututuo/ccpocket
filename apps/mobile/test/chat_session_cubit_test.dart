import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal mock BridgeService for testing the cubit.
class MockBridgeService extends BridgeService {
  final _messageController = StreamController<ServerMessage>.broadcast();
  final _taggedController =
      StreamController<(ServerMessage, String?)>.broadcast();
  final _connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final _localFeatureController =
      StreamController<(LocalFeatureServerMessage, String)>.broadcast();
  final _sessionListController =
      StreamController<List<SessionInfo>>.broadcast();
  final sentMessages = <ClientMessage>[];
  final updatedOfflineInputs = <Map<String, dynamic>>[];
  final canceledOfflineInputs = <Map<String, dynamic>>[];
  final restoredCodexModels = <Map<String, dynamic>>[];
  final restoredCodexSpeeds = <Map<String, dynamic>>[];
  final interruptedSessionIds = <String>[];
  final stoppedSessionIds = <String>[];
  final cachedMessagesBySession = <String, List<ServerMessage>>{};
  final historySeqBySession = <String, int>{};
  bool connected = true;
  bool offlineUpdateSucceeds = true;
  bool offlineCancelSucceeds = true;
  int authoritativeGeneration = 0;
  bool authoritativeForCurrentConnection = true;
  String? sourceId = 'source-a';
  List<SessionInfo> sessionSnapshot = const [];
  Set<String> advertisedBridgeCapabilities = const {
    ChatSessionCubit.codexDesktopContinuityCapability,
  };

  void emitMessage(ServerMessage msg, {String? sessionId}) {
    _taggedController.add((msg, sessionId));
    _messageController.add(msg);
  }

  void emitConnection(BridgeConnectionState state) {
    connected = state == BridgeConnectionState.connected;
    if (!connected) authoritativeForCurrentConnection = false;
    _connectionController.add(state);
  }

  void emitLocalFeature(
    LocalFeatureServerMessage message, {
    required String sessionId,
  }) {
    _localFeatureController.add((message, sessionId));
  }

  void emitSessions(List<SessionInfo> sessions) {
    authoritativeGeneration++;
    authoritativeForCurrentConnection = true;
    sessionSnapshot = sessions;
    _sessionListController.add(sessions);
  }

  @override
  Stream<ServerMessage> get messages => _messageController.stream;

  @override
  bool get isConnected => connected;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _connectionController.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionListController.stream;

  @override
  List<SessionInfo> get sessions => sessionSnapshot;

  @override
  int get authoritativeSessionListGeneration => authoritativeGeneration;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      connected && authoritativeForCurrentConnection;

  @override
  Set<String> get bridgeCapabilities => advertisedBridgeCapabilities;

  @override
  String? get codexSourceId => sourceId;

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) {
    return _taggedController.stream
        .where((pair) => pair.$2 == null || pair.$2 == sessionId)
        .map((pair) => pair.$1);
  }

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) {
    return _localFeatureController.stream
        .where((pair) => pair.$2 == sessionId)
        .map((pair) => pair.$1);
  }

  @override
  void send(ClientMessage message) {
    if (!connected && message.delivery == ClientMessageDelivery.ephemeral) {
      throw StateError('Bridge is not connected.');
    }
    sentMessages.add(message);
  }

  @override
  Future<bool> updateOfflinePendingInput({
    required String sessionId,
    required String clientMessageId,
    required String text,
    List<Map<String, String>>? skills,
    List<Map<String, String>>? mentions,
  }) async {
    updatedOfflineInputs.add({
      'sessionId': sessionId,
      'clientMessageId': clientMessageId,
      'text': text,
      'skills': skills,
      'mentions': mentions,
    });
    return offlineUpdateSucceeds;
  }

  @override
  Future<bool> cancelOfflinePendingInput({
    required String sessionId,
    required String clientMessageId,
  }) async {
    canceledOfflineInputs.add({
      'sessionId': sessionId,
      'clientMessageId': clientMessageId,
    });
    return offlineCancelSucceeds;
  }

  @override
  void restoreSessionCodexModel(
    String sessionId, {
    required String? model,
    required String? modelReasoningEffort,
  }) {
    restoredCodexModels.add({
      'sessionId': sessionId,
      'model': model,
      'modelReasoningEffort': modelReasoningEffort,
    });
  }

  @override
  void restoreSessionCodexSpeed(String sessionId, String? serviceTier) {
    restoredCodexSpeeds.add({
      'sessionId': sessionId,
      'serviceTier': serviceTier,
    });
  }

  @override
  void interrupt(String sessionId) {
    interruptedSessionIds.add(sessionId);
  }

  @override
  void stopSession(String sessionId) {
    stoppedSessionIds.add(sessionId);
  }

  @override
  void requestFileList(String projectPath) {
    // no-op for tests
  }

  @override
  void requestSessionList() {
    // no-op for tests
  }

  int requestSessionHistoryCallCount = 0;
  String? lastRequestedSessionId;

  @override
  void requestSessionHistory(String sessionId) {
    requestSessionHistoryCallCount++;
    lastRequestedSessionId = sessionId;
  }

  @override
  List<ServerMessage> cachedSessionMessages(String sessionId) {
    return cachedMessagesBySession[sessionId] ?? const [];
  }

  @override
  int cachedSessionHistorySeq(String sessionId) {
    return historySeqBySession[sessionId] ?? 0;
  }

  @override
  void dispose() {
    _messageController.close();
    _taggedController.close();
    _connectionController.close();
    _localFeatureController.close();
    _sessionListController.close();
    super.dispose();
  }
}

void main() {
  late MockBridgeService mockBridge;
  late StreamingStateCubit streamingCubit;

  setUp(() {
    mockBridge = MockBridgeService();
    streamingCubit = StreamingStateCubit(coalesceInterval: Duration.zero);
  });

  tearDown(() {
    streamingCubit.close();
    mockBridge.dispose();
  });

  ChatSessionCubit createCubit(
    String sessionId, {
    Provider? provider,
    String? initialProjectPath,
    ChatImagePayloadEncoder? imagePayloadEncoder,
  }) {
    return ChatSessionCubit(
      sessionId: sessionId,
      provider: provider,
      bridge: mockBridge,
      streamingCubit: streamingCubit,
      initialProjectPath: initialProjectPath,
      imagePayloadEncoder: imagePayloadEncoder,
    );
  }

  group('ChatSessionCubit', () {
    test(
      'dismissed Codex warning stays hidden across canonical history replay',
      () async {
        const warning = ErrorMessage(
          message: 'thread/rollback is deprecated',
          errorCode: 'codex_warning',
        );
        const otherWarning = ErrorMessage(
          message: 'A different warning',
          errorCode: 'codex_warning',
        );
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        mockBridge.emitMessage(warning, sessionId: 's1');
        await pumpEventQueue();
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().map(
            (entry) => entry.message,
          ),
          contains(warning),
        );

        cubit.dismissCodexWarning(warning);
        expect(cubit.state.entries, isEmpty);

        mockBridge.emitMessage(
          const HistoryMessage(messages: [warning, otherWarning]),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final messages = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .toList();
        expect(messages, isNot(contains(warning)));
        expect(messages, contains(otherWarning));
      },
    );

    test('initial state is default ChatSessionState', () {
      final cubit = createCubit('test-session');
      addTearDown(cubit.close);

      expect(cubit.state.status, ProcessStatus.starting);
      expect(cubit.state.entries, isEmpty);
      expect(cubit.state.approval, isA<ApprovalNone>());
      expect(cubit.state.totalCost, 0.0);
    });

    test(
      'detached preview renders cached history without live requests or sends',
      () async {
        final cubit = ChatSessionCubit(
          sessionId: 'durable-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialHistoryMessages: const [
            UserInputMessage(text: 'Cached question'),
            AssistantServerMessage(
              message: AssistantMessage(
                id: 'assistant-1',
                role: 'assistant',
                content: [TextContent(text: 'Cached answer')],
                model: 'gpt-test',
              ),
            ),
          ],
        );
        addTearDown(cubit.close);

        expect(cubit.state.status, ProcessStatus.idle);
        expect(cubit.state.entries, hasLength(2));
        expect(mockBridge.requestSessionHistoryCallCount, 0);

        cubit.sendMessage('must not be sent');
        cubit.refreshHistory();
        await pumpEventQueue();

        expect(mockBridge.sentMessages, isEmpty);
        expect(mockBridge.requestSessionHistoryCallCount, 0);

        expect(cubit.showDeferredSubmission('Send while attaching'), isTrue);
        expect(
          cubit.state.entries.whereType<UserChatEntry>().last.status,
          MessageStatus.sending,
        );
        cubit.updateDetachedPreviewHistory(const [
          UserInputMessage(text: 'Cached question'),
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: [TextContent(text: 'Cached answer')],
              model: 'gpt-test',
            ),
          ),
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-2',
              role: 'assistant',
              content: [TextContent(text: 'New cached increment')],
              model: 'gpt-test',
            ),
          ),
        ]);

        expect(
          cubit.state.entries.whereType<UserChatEntry>().map(
            (entry) => entry.text,
          ),
          contains('Send while attaching'),
        );
        expect(
          cubit.showDeferredSubmission(
            'Queued while offline',
            queuedLocally: true,
          ),
          isTrue,
        );
        expect(
          cubit.state.entries.whereType<UserChatEntry>().last.status,
          MessageStatus.queued,
        );
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().where(
            (entry) =>
                entry.message is AssistantServerMessage &&
                (entry.message as AssistantServerMessage).message.id ==
                    'assistant-2',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'detached provider status stays source-scoped and rejects late history',
      () async {
        final cubit = ChatSessionCubit(
          sessionId: 'durable-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'ownedElsewhere',
            source: 'legacyRollout',
            confidence: 'observed',
            observedAt: '2026-07-31T04:00:00.000Z',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.externalDesktopTurnActive, isTrue);
        expect(cubit.externalDesktopTurnSteerable.value, isFalse);
        cubit.updateDetachedProviderSettings(
          const RecentSession(
            sessionId: 'durable-thread',
            provider: 'codex',
            firstPrompt: 'Task',
            created: '2026-07-31T03:00:00.000Z',
            modified: '2026-07-31T04:00:00.000Z',
            gitBranch: 'main',
            projectPath: '/tmp/project',
            isSidechain: false,
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'default',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.state.codexModel, 'gpt-5.6-sol');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);

        cubit.updateDetachedPreviewHistory(const [
          StatusMessage(status: ProcessStatus.idle),
          SystemMessage(
            subtype: 'init',
            provider: 'codex',
            model: 'gpt-5.6-sol',
            modelReasoningEffort: 'high',
            serviceTier: 'fast',
          ),
          UserInputMessage(text: 'Cached update'),
        ]);
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
        expect(cubit.state.codexSpeed, CodexSpeed.standard);
        expect(cubit.codexServiceTierRaw.value, 'default');

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'another-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'notLoaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-07-31T04:01:00.000Z',
          ),
        );
        expect(cubit.state.status, ProcessStatus.running);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'notLoaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-07-31T03:59:00.000Z',
          ),
        );
        expect(cubit.state.status, ProcessStatus.running);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-thread',
            activity: 'idle',
            attention: 'none',
            result: 'completed',
            runtimeAttachment: 'notLoaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-07-31T04:02:00.000Z',
          ),
        );
        expect(cubit.state.status, ProcessStatus.idle);
        expect(cubit.state.externalDesktopTurnActive, isFalse);

        cubit.updateDetachedProviderStatus(
          null,
          sourceFingerprint: 'bridge-b/source-b',
        );
        expect(cubit.state.status, ProcessStatus.unknown);
        expect(cubit.state.codexModel, isNull);
        expect(cubit.state.codexModelReasoningEffort, isNull);
        expect(cubit.state.codexSpeed, CodexSpeed.unknown);
        expect(cubit.codexServiceTierRaw.value, isNull);
      },
    );

    test(
      'detached provider status separates evidence source from turn authority',
      () async {
        final cubit = ChatSessionCubit(
          sessionId: 'shared-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'shared-runtime',
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'shared-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T00:00:00.000Z',
            executionHost: 'bridge',
            activeTurnId: 'turn-bridge',
            controlState: 'writable',
            authorityGeneration: 'authority-1',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );

        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.externalDesktopTurnId, isNull);
        expect(cubit.externalDesktopTurnSteerable.value, isFalse);
        expect(cubit.detachedActionBrokerTurnId, 'turn-bridge');
        expect(cubit.detachedActionBrokerAuthorityGeneration, 'authority-1');
        expect(cubit.detachedActionBrokerExecutionHost, 'bridge');

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'shared-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T00:01:00.000Z',
            executionHost: 'desktopAppServer',
            activeTurnId: 'turn-desktop',
            controlState: 'readOnly',
            authorityGeneration: 'authority-2',
          ),
        );

        expect(cubit.state.externalDesktopTurnActive, isTrue);
        expect(cubit.state.externalDesktopTurnId, 'turn-desktop');
        expect(cubit.externalDesktopTurnSteerable.value, isFalse);
        expect(cubit.detachedActionBrokerTurnId, 'turn-desktop');
        expect(cubit.detachedActionBrokerAuthorityGeneration, 'authority-2');
        expect(cubit.detachedActionBrokerExecutionHost, 'desktopAppServer');

        // A same-timestamp authority update must still apply. The opaque
        // generation is part of the semantic status signature, not a clock.
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'shared-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T00:01:00.000Z',
            executionHost: 'desktopAppServer',
            activeTurnId: 'turn-desktop',
            controlState: 'steerable',
            authorityGeneration: 'authority-3',
          ),
        );
        expect(cubit.externalDesktopTurnSteerable.value, isTrue);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'shared-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T00:02:00.000Z',
            executionHost: 'unknown',
            activeTurnId: 'turn-unknown',
            controlState: 'unavailable',
            authorityGeneration: 'authority-4',
          ),
        );
        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.externalDesktopTurnId, isNull);
        expect(cubit.externalDesktopTurnSteerable.value, isFalse);

        // Old Bridges omit all authority fields. Preserve the legacy source
        // fallback without claiming that the turn is controllable.
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'shared-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'ownedElsewhere',
            source: 'legacyRollout',
            confidence: 'observed',
            observedAt: '2026-08-01T00:03:00.000Z',
          ),
        );
        expect(cubit.state.externalDesktopTurnActive, isTrue);
        expect(cubit.state.externalDesktopTurnId, isNull);
        expect(cubit.externalDesktopTurnSteerable.value, isFalse);
      },
    );

    test(
      'detached settings wait for exact authority and never update optimistically',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'settings-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'settings-runtime',
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderSettings(
          const RecentSession(
            sessionId: 'settings-thread',
            provider: 'codex',
            rawPermissionMode: 'bypassPermissions',
            firstPrompt: 'Settings test',
            created: '2026-08-01T01:00:00.000Z',
            modified: '2026-08-01T01:01:00.000Z',
            gitBranch: 'main',
            projectPath: '/tmp/project',
            isSidechain: false,
            codexApprovalPolicy: 'never',
            codexApprovalsReviewer: 'user',
            codexPermissionsMode: 'fullAccess',
            codexSandboxMode: 'danger-full-access',
            codexCollaborationMode: 'default',
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'fast',
            codexSettingsSnapshotComplete: true,
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );

        expect(
          cubit.codexSettingsActionability,
          CodexSettingsActionability.waitingForRuntime,
        );
        expect(cubit.codexModelSettingsKnown, isTrue);
        expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.fullAccess,
        );
        expect(cubit.state.sandboxMode, SandboxMode.off);

        cubit.setCodexModel(
          'gpt-5.4-mini',
          reasoningEffort: ReasoningEffort.low,
        );
        expect(mockBridge.sentMessages, isEmpty);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'settings-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:02:00.000Z',
            executionHost: 'bridge',
            controlState: 'writable',
            authorityGeneration: 'settings-authority-1',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(
          cubit.codexSettingsActionability,
          CodexSettingsActionability.editable,
        );

        cubit.setCodexModel(
          'gpt-5.4-mini',
          reasoningEffort: ReasoningEffort.low,
        );

        expect(cubit.state.codexModel, 'gpt-5.6-sol');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
        final settingsMessage = mockBridge.sentMessages.single;
        final settingsPayload =
            jsonDecode(settingsMessage.toJson()) as Map<String, dynamic>;
        expect(settingsMessage.delivery, ClientMessageDelivery.ephemeral);
        expect(settingsPayload['type'], 'set_codex_model');
        expect(settingsPayload['sessionId'], 'settings-runtime');
        expect(settingsPayload['codexSourceId'], 'source-a');
        expect(settingsPayload['threadId'], 'settings-thread');
        expect(settingsPayload['runtimeSessionId'], 'settings-runtime');
        expect(settingsPayload['authorityGeneration'], 'settings-authority-1');
        expect(settingsPayload['operationId'], isNotEmpty);

        mockBridge.sentMessages.clear();
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'settings-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:03:00.000Z',
            executionHost: 'desktopAppServer',
            controlState: 'readOnly',
            authorityGeneration: 'settings-authority-2',
          ),
        );
        expect(
          cubit.codexSettingsActionability,
          CodexSettingsActionability.readOnlyDesktopOwner,
        );

        cubit.setCodexSpeed(CodexSpeed.standard);
        expect(cubit.state.codexSpeed, CodexSpeed.fast);
        expect(mockBridge.sentMessages, isEmpty);

        cubit.updateDetachedProviderStatus(
          null,
          sourceFingerprint: 'bridge-b/source-b',
        );
        expect(cubit.state.codexPermissionStateKnown, isFalse);
        expect(cubit.state.codexModel, isNull);
        expect(cubit.state.codexModelReasoningEffort, isNull);
        expect(cubit.state.codexSpeed, CodexSpeed.unknown);
      },
    );

    test(
      'detached settings factories share one exact ephemeral authority envelope',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-settings',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-settings',
        );
        addTearDown(cubit.close);
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-settings',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:10:00.000Z',
            executionHost: 'bridge',
            controlState: 'writable',
            authorityGeneration: 'authority-settings',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );

        cubit.setSessionModes(planMode: true);
        cubit.setCodexApprovalPolicy(CodexApprovalPolicy.never);
        cubit.setCodexPermissionsMode(CodexPermissionsMode.fullAccess);
        cubit.setCodexModel(
          'gpt-5.6-sol',
          reasoningEffort: ReasoningEffort.high,
        );
        cubit.setCodexSpeed(CodexSpeed.fast);
        cubit.setSandboxMode(SandboxMode.off);

        expect(mockBridge.sentMessages, hasLength(6));
        final operationIds = <String>{};
        for (final message in mockBridge.sentMessages) {
          final payload = jsonDecode(message.toJson()) as Map<String, dynamic>;
          expect(message.delivery, ClientMessageDelivery.ephemeral);
          expect(payload['sessionId'], 'runtime-settings');
          expect(payload['codexSourceId'], 'source-a');
          expect(payload['threadId'], 'durable-settings');
          expect(payload['runtimeSessionId'], 'runtime-settings');
          expect(payload['authorityGeneration'], 'authority-settings');
          expect(payload['operationId'], isA<String>());
          operationIds.add(payload['operationId'] as String);
        }
        expect(operationIds, hasLength(6));

        mockBridge.sentMessages.clear();
        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        cubit.setCodexModel(
          'gpt-5.4-mini',
          reasoningEffort: ReasoningEffort.low,
        );
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test(
      'v2 complete settings clear missing facts while legacy sparse rows retain them',
      () async {
        final cubit = ChatSessionCubit(
          sessionId: 'settings-snapshot-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderSettings(
          const RecentSession(
            sessionId: 'settings-snapshot-thread',
            provider: 'codex',
            firstPrompt: '',
            created: '2026-08-01T02:00:00.000Z',
            modified: '2026-08-01T02:01:00.000Z',
            gitBranch: '',
            projectPath: '/tmp/project',
            isSidechain: false,
            codexApprovalPolicy: 'never',
            codexApprovalsReviewer: 'user',
            codexSandboxMode: 'danger-full-access',
            codexCollaborationMode: 'plan',
            planMode: true,
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'fast',
            codexSettingsSnapshotComplete: true,
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.state.codexPermissionStateKnown, isTrue);
        expect(cubit.state.planMode, isTrue);
        expect(cubit.state.codexModel, 'gpt-5.6-sol');

        cubit.updateDetachedProviderSettings(
          const RecentSession(
            sessionId: 'settings-snapshot-thread',
            provider: 'codex',
            firstPrompt: '',
            created: '2026-08-01T02:00:00.000Z',
            modified: '2026-08-01T02:02:00.000Z',
            gitBranch: '',
            projectPath: '/tmp/project',
            isSidechain: false,
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.state.codexPermissionStateKnown, isTrue);
        expect(cubit.state.planMode, isTrue);
        expect(cubit.state.codexModel, 'gpt-5.6-sol');

        cubit.updateDetachedProviderSettings(
          const RecentSession(
            sessionId: 'settings-snapshot-thread',
            provider: 'codex',
            firstPrompt: '',
            created: '2026-08-01T02:00:00.000Z',
            modified: '2026-08-01T02:03:00.000Z',
            gitBranch: '',
            projectPath: '/tmp/project',
            isSidechain: false,
            codexSettingsSnapshotComplete: true,
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.state.codexPermissionStateKnown, isFalse);
        expect(cubit.state.planMode, isFalse);
        expect(cubit.state.sandboxMode, SandboxMode.on);
        expect(cubit.state.codexModel, isNull);
        expect(cubit.state.codexModelReasoningEffort, isNull);
        expect(cubit.state.codexSpeed, CodexSpeed.unknown);
      },
    );

    test(
      'detached runtime capability queries use the live runtime id',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
          ChatSessionCubit.codexPermissionApplyStrategyCapability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-capability-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'live-capability-runtime',
        );
        addTearDown(cubit.close);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 'durable-capability-thread',
            provider: 'codex',
            projectPath: '/durable',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexPermissionApplyStrategySupported: true,
            codexNativePlanModeSupported: false,
            codexGoalControlSupported: false,
          ),
          SessionInfo(
            id: 'live-capability-runtime',
            provider: 'codex',
            projectPath: '/runtime',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexPermissionApplyStrategySupported: false,
            codexNativePlanModeSupported: true,
            codexGoalControlSupported: true,
          ),
        ]);
        await pumpEventQueue();

        expect(cubit.supportsCodexPermissionApplyStrategy, isFalse);
        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.supported,
        );
        expect(cubit.state.goalSupport, CodexGoalSupport.supported);
        expect(cubit.state.advancedGoalControlSupported, isTrue);
      },
    );

    test(
      'durable preview overlays one live runtime without replacing cache identity',
      () async {
        const cachedUser = UserInputMessage(
          text: 'Cached request',
          userMessageUuid: 'cached-user-1',
        );
        const liveAssistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-live-1',
            role: 'assistant',
            content: [TextContent(text: 'Live answer')],
            model: 'gpt-test',
          ),
        );
        final cubit = ChatSessionCubit(
          sessionId: 'durable-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialHistoryMessages: const [cachedUser],
        );
        addTearDown(cubit.close);

        expect(cubit.sendMessage('Must attach first'), isFalse);
        expect(mockBridge.sentMessages, isEmpty);

        cubit.updateDetachedLiveRuntime('runtime-a');
        expect(cubit.detachedLiveRuntimeSessionId, 'runtime-a');
        expect(
          cubit.sendMessage(
            'Continue from cache',
            clientMessageId: 'client-message-1',
          ),
          isTrue,
        );
        final sent = jsonDecode(mockBridge.sentMessages.single.toJson());
        expect(sent['sessionId'], 'runtime-a');

        mockBridge.emitMessage(liveAssistant, sessionId: 'runtime-a');
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().where(
            (entry) =>
                entry.message is AssistantServerMessage &&
                (entry.message as AssistantServerMessage).message.id ==
                    'assistant-live-1',
          ),
          hasLength(1),
        );

        // A runtime history snapshot is not another timeline authority.
        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              UserInputMessage(
                text: 'Runtime snapshot must not replace the cache',
                userMessageUuid: 'runtime-history-user',
              ),
            ],
          ),
          sessionId: 'runtime-a',
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.entries.whereType<UserChatEntry>().where(
            (entry) =>
                entry.text == 'Runtime snapshot must not replace the cache',
          ),
          isEmpty,
        );

        // When SQLite catches up with the live item, stable IDs reconcile it
        // rather than appending a second copy or moving the page identity.
        cubit.updateDetachedPreviewHistory(const [cachedUser, liveAssistant]);
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().where(
            (entry) =>
                entry.message is AssistantServerMessage &&
                (entry.message as AssistantServerMessage).message.id ==
                    'assistant-live-1',
          ),
          hasLength(1),
        );
        expect(cubit.sessionId, 'durable-thread');
      },
    );

    test(
      'durable runtime authority is cleared when the authenticated source changes',
      () {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-a',
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:00:00.000Z',
            executionHost: 'bridge',
            controlState: 'writable',
            authorityGeneration: 'source-a-generation',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.sendMessage('Source A write'), isTrue);
        mockBridge.sentMessages.clear();

        cubit.updateDetachedProviderStatus(
          null,
          sourceFingerprint: 'bridge-b/source-b',
        );
        expect(cubit.canMutateAttachedRuntime, isFalse);
        expect(cubit.sendMessage('Must wait for source B authority'), isFalse);
        expect(mockBridge.sentMessages, isEmpty);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:01:00.000Z',
            executionHost: 'bridge',
            controlState: 'writable',
            authorityGeneration: 'source-b-generation',
          ),
          sourceFingerprint: 'bridge-b/source-b',
        );
        expect(cubit.sendMessage('Source B write'), isTrue);
        expect(
          jsonDecode(mockBridge.sentMessages.single.toJson())['sessionId'],
          'runtime-a',
        );
      },
    );

    test(
      'unknown host can start a turn only with an exact writable authority lease',
      () {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-unknown-host',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-unknown-host',
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-unknown-host',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:10:00.000Z',
            executionHost: 'unknown',
            controlState: 'writable',
            authorityGeneration: 'authority-writable',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );

        expect(cubit.sendMessage('Start on exact writable lease'), isTrue);
        expect(
          jsonDecode(mockBridge.sentMessages.single.toJson())['sessionId'],
          'runtime-unknown-host',
        );
        mockBridge.sentMessages.clear();

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-unknown-host',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:11:00.000Z',
            executionHost: 'unknown',
            activeTurnId: 'turn-unproven',
            controlState: 'steerable',
            authorityGeneration: 'authority-steerable',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );

        expect(cubit.sendMessage('Do not steer an unproven host'), isFalse);
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test(
      'runtime replacement clears transient approval and rejects its old action',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-transient-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-transient-old',
        );
        addTearDown(cubit.close);
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-transient-thread',
            activity: 'working',
            attention: 'approval',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:20:00.000Z',
            executionHost: 'bridge',
            activeTurnId: 'turn-old',
            controlState: 'steerable',
            authorityGeneration: 'authority-old',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'approval-old',
            toolName: 'Bash',
            input: {'command': 'old'},
          ),
          sessionId: 'runtime-transient-old',
        );
        await pumpEventQueue();
        expect(cubit.state.approval, isA<ApprovalPermission>());

        cubit.updateDetachedLiveRuntime('runtime-transient-new');

        expect(cubit.state.approval, isA<ApprovalNone>());
        expect(cubit.state.queuedInput, isNull);
        expect(cubit.state.status, ProcessStatus.unknown);
        cubit.approve('approval-old');
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test(
      'source replacement clears transient approval and rejects its old action',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-source-transient',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-source-transient',
        );
        addTearDown(cubit.close);
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-source-transient',
            activity: 'working',
            attention: 'approval',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:25:00.000Z',
            executionHost: 'bridge',
            activeTurnId: 'turn-source-a',
            controlState: 'steerable',
            authorityGeneration: 'authority-source-a',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'approval-source-a',
            toolName: 'Bash',
            input: {'command': 'source-a'},
          ),
          sessionId: 'runtime-source-transient',
        );
        await pumpEventQueue();
        expect(cubit.state.approval, isA<ApprovalPermission>());

        cubit.updateDetachedProviderStatus(
          null,
          sourceFingerprint: 'bridge-b/source-b',
        );

        expect(cubit.state.approval, isA<ApprovalNone>());
        cubit.approve('approval-source-a');
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test(
      'image dispatch keeps its runtime source and authority lease',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final encoded = Completer<List<Map<String, String>>>();
        final cubit = ChatSessionCubit(
          sessionId: 'durable-image-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-image-old',
          imagePayloadEncoder: (_) => encoded.future,
        );
        addTearDown(cubit.close);
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-image-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:40:00.000Z',
            executionHost: 'bridge',
            controlState: 'writable',
            authorityGeneration: 'authority-image-old',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );

        expect(
          cubit.sendMessage(
            'Image must stay on its lease',
            images: [
              (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
            ],
          ),
          isTrue,
        );
        expect(
          cubit.sendMessage('Serialized text must stay on the same lease'),
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);

        cubit.updateDetachedLiveRuntime('runtime-image-new');
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-image-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:41:00.000Z',
            executionHost: 'bridge',
            controlState: 'writable',
            authorityGeneration: 'authority-image-new',
          ),
          sourceFingerprint: 'bridge-b/source-b',
        );
        encoded.complete(const [
          {'base64': 'AQID', 'mimeType': 'image/png'},
        ]);
        await pumpEventQueue();

        expect(mockBridge.sentMessages, isEmpty);
        expect(
          cubit.state.entries.whereType<UserChatEntry>().map(
            (entry) => entry.status,
          ),
          everyElement(MessageStatus.failed),
        );
      },
    );

    test(
      'a replacement runtime cannot inherit writable authority from the old handle',
      () {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-runtime-generation',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-old',
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-runtime-generation',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:30:00.000Z',
            executionHost: 'bridge',
            activeTurnId: 'turn-old',
            controlState: 'writable',
            authorityGeneration: 'authority-old',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.sendMessage('Old handle write'), isTrue);
        mockBridge.sentMessages.clear();

        cubit.updateDetachedLiveRuntime('runtime-new');
        expect(cubit.canMutateAttachedRuntime, isFalse);
        expect(cubit.sendMessage('Must not inherit authority'), isFalse);
        expect(mockBridge.sentMessages, isEmpty);

        // The updater immediately replays the current catalog row after a
        // handle replacement. Its old authority generation may refresh
        // read-only presentation, but it cannot unlock the new runtime.
        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-runtime-generation',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:30:30.000Z',
            executionHost: 'bridge',
            activeTurnId: 'turn-old',
            controlState: 'writable',
            authorityGeneration: 'authority-old',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.canMutateAttachedRuntime, isFalse);
        expect(
          cubit.sendMessage('Rejected generation stays read-only'),
          isFalse,
        );
        expect(mockBridge.sentMessages, isEmpty);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-runtime-generation',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T01:31:00.000Z',
            executionHost: 'bridge',
            activeTurnId: 'turn-new',
            controlState: 'writable',
            authorityGeneration: 'authority-new',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.sendMessage('New handle write'), isTrue);
        expect(
          jsonDecode(mockBridge.sentMessages.single.toJson())['sessionId'],
          'runtime-new',
        );
      },
    );

    test(
      'legacy detached authority blocks an active external turn but keeps idle compatibility',
      () {
        final cubit = ChatSessionCubit(
          sessionId: 'durable-legacy-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'legacy-runtime',
        );
        addTearDown(cubit.close);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-legacy-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'ownedElsewhere',
            source: 'appServer',
            confidence: 'observed',
            observedAt: '2026-08-01T02:00:00.000Z',
          ),
          sourceFingerprint: 'legacy-bridge/source',
        );
        expect(cubit.state.externalDesktopTurnActive, isTrue);
        expect(cubit.sendMessage('Do not write foreign legacy turn'), isFalse);

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-legacy-thread',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'observed',
            observedAt: '2026-08-01T02:01:00.000Z',
          ),
          sourceFingerprint: 'legacy-bridge/source',
        );
        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.sendMessage('Legacy idle write'), isTrue);
        expect(
          jsonDecode(mockBridge.sentMessages.single.toJson())['sessionId'],
          'legacy-runtime',
        );
      },
    );

    test(
      'durable runtime operations fail closed until writable and target only the live handle',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
          codexRuntimeDetachCapability,
        };
        final cubit = ChatSessionCubit(
          sessionId: 'durable-operations-thread',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          detachedPreview: true,
          initialLiveRuntimeSessionId: 'runtime-operations',
        );
        addTearDown(cubit.close);
        final queued = QueuedInputItem(
          itemId: 'queued-1',
          text: 'Queued text',
          createdAt: DateTime.utc(2026, 8, 1).toIso8601String(),
        );
        final failedEntry = UserChatEntry(
          'Retry text',
          sessionId: 'durable-operations-thread',
          status: MessageStatus.failed,
        );

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-operations-thread',
            activity: 'working',
            attention: 'approval',
            result: 'none',
            runtimeAttachment: 'ownedElsewhere',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T03:00:00.000Z',
            executionHost: 'desktopAppServer',
            activeTurnId: 'foreign-turn',
            controlState: 'readOnly',
            authorityGeneration: 'read-only-generation',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.sendMessage('Blocked input'), isFalse);
        expect(await cubit.updateQueuedInput(queued, 'Blocked queue'), isFalse);
        expect(await cubit.cancelQueuedInput(queued), isFalse);
        cubit.approve('approval-blocked');
        cubit.reject('rejection-blocked');
        cubit.answer('answer-blocked', 'No');
        cubit.retryMessage(failedEntry);
        cubit.setPermissionMode(PermissionMode.auto);
        cubit.setCodexModel(
          'gpt-5.6-sol',
          reasoningEffort: ReasoningEffort.ultra,
        );
        cubit.setCodexSpeed(CodexSpeed.fast);
        cubit.setSandboxMode(SandboxMode.off);
        expect(mockBridge.sentMessages, isEmpty);
        expect(mockBridge.interruptedSessionIds, isEmpty);
        expect(cubit.stopActionDetachesDesktopTurn, isTrue);
        cubit.interrupt();
        expect(jsonDecode(mockBridge.sentMessages.single.toJson()), {
          'type': 'detach_session',
          'sessionId': 'runtime-operations',
          'codexSourceId': 'source-a',
          'threadId': 'durable-operations-thread',
          'authorityGeneration': 'read-only-generation',
        });
        expect(mockBridge.interruptedSessionIds, isEmpty);
        mockBridge.sentMessages.clear();

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-operations-thread',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T03:00:30.000Z',
            executionHost: 'desktopAppServer',
            activeTurnId: 'desktop-turn',
            controlState: 'steerable',
            authorityGeneration: 'desktop-steer-generation',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        cubit.steerQueuedInput(queued);
        final desktopSteer =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(desktopSteer, {
          'type': 'steer_queued_input',
          'sessionId': 'runtime-operations',
          'itemId': queued.itemId,
          'expectedTurnId': 'desktop-turn',
          'codexSourceId': 'source-a',
          'threadId': 'durable-operations-thread',
          'authorityGeneration': 'desktop-steer-generation',
        });
        mockBridge.sentMessages.clear();

        cubit.updateDetachedProviderStatus(
          const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'durable-operations-thread',
            activity: 'working',
            attention: 'approval',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-08-01T03:01:00.000Z',
            executionHost: 'bridge',
            activeTurnId: 'bridge-turn',
            controlState: 'writable',
            authorityGeneration: 'writable-generation',
          ),
          sourceFingerprint: 'bridge-a/source-a',
        );
        expect(cubit.canMutateAttachedRuntime, isTrue);
        expect(await cubit.updateQueuedInput(queued, 'Updated queue'), isTrue);
        cubit.steerQueuedInput(queued);
        expect(await cubit.cancelQueuedInput(queued), isTrue);
        cubit.approve('approval-1');
        cubit.reject('rejection-1');
        cubit.answer('answer-1', 'Yes');
        cubit.interrupt();
        cubit.stop();
        cubit.setPermissionMode(PermissionMode.auto);
        cubit.setCodexModel(
          'gpt-5.6-sol',
          reasoningEffort: ReasoningEffort.ultra,
        );
        cubit.setCodexSpeed(CodexSpeed.fast);
        cubit.setSandboxMode(SandboxMode.off);

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'runtime-operations',
            claudeSessionId: 'durable-operations-thread',
            provider: 'codex',
          ),
          sessionId: 'runtime-operations',
        );
        await pumpEventQueue();
        mockBridge.emitMessage(
          const GoalStateMessage(
            sessionId: 'runtime-operations',
            goal: null,
            goalOperationSequence: 1,
          ),
          sessionId: 'runtime-operations',
        );
        await pumpEventQueue();
        expect(cubit.startGoal('Keep durable identity'), isTrue);

        final payloads = mockBridge.sentMessages
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .toList(growable: false);
        expect(payloads, isNotEmpty);
        expect(
          payloads.where((payload) => payload.containsKey('sessionId')),
          everyElement(containsPair('sessionId', 'runtime-operations')),
        );
        expect(
          payloads.map((payload) => payload['type']),
          containsAll(<String>[
            'update_queued_input',
            'steer_queued_input',
            'cancel_queued_input',
            'approve',
            'reject',
            'answer',
            'set_permission_mode',
            'set_codex_model',
            'set_codex_speed',
            'set_sandbox_mode',
            'get_goal',
            'set_goal',
          ]),
        );
        expect(mockBridge.interruptedSessionIds, ['runtime-operations']);
        expect(mockBridge.stoppedSessionIds, ['runtime-operations']);
        expect(cubit.sessionId, 'durable-operations-thread');
      },
    );

    test(
      'Codex native Plan capability follows session_list and resets on disconnect',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.unknown,
        );
        mockBridge.emitSessions([
          const SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexNativePlanModeSupported: true,
          ),
        ]);
        await Future.microtask(() {});
        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.supported,
        );

        mockBridge.emitSessions([
          const SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexNativePlanModeSupported: false,
          ),
        ]);
        await Future.microtask(() {});
        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.unsupported,
        );

        mockBridge.emitSessions([
          const SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await Future.microtask(() {});
        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.unknown,
        );

        mockBridge.emitSessions([
          const SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexNativePlanModeSupported: true,
          ),
        ]);
        await Future.microtask(() {});
        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        await Future.microtask(() {});
        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.unknown,
        );
      },
    );

    test('Codex toolbar hydrates from the authoritative session snapshot', () {
      mockBridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
          permissionMode: 'bypassPermissions',
          executionMode: 'fullAccess',
          codexApprovalPolicy: 'never',
          codexApprovalsReviewer: 'user',
          codexPermissionsMode: 'fullAccess',
          codexSandboxMode: 'danger-full-access',
          codexModel: 'gpt-5.6-sol',
          codexModelReasoningEffort: 'ultra',
          codexServiceTier: 'fast',
        ),
      ];

      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
      expect(cubit.state.executionMode, ExecutionMode.fullAccess);
      expect(cubit.state.codexPermissionStateKnown, isTrue);
      expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.never);
      expect(cubit.state.codexPermissionsMode, CodexPermissionsMode.fullAccess);
      expect(cubit.state.sandboxMode, SandboxMode.off);
      expect(cubit.state.codexModel, 'gpt-5.6-sol');
      expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
      expect(cubit.state.codexSpeed, CodexSpeed.fast);
    });

    test(
      'session refresh synchronizes settings without overwriting a pending next-turn permission change',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            codexApprovalPolicy: 'on-request',
            codexApprovalsReviewer: 'user',
            codexPermissionsMode: 'default',
            codexSandboxMode: 'workspace-write',
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'high',
            codexServiceTier: 'standard',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        cubit.setCodexPermissionsMode(
          CodexPermissionsMode.autoReview,
          applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        );
        expect(cubit.isPermissionChangePending, isTrue);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            codexApprovalPolicy: 'on-request',
            codexApprovalsReviewer: 'user',
            codexPermissionsMode: 'default',
            codexSandboxMode: 'workspace-write',
            codexModel: 'gpt-5.6-terra',
            codexModelReasoningEffort: 'medium',
            codexServiceTier: 'fast',
          ),
        ]);
        await Future.microtask(() {});

        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.autoReview,
        );
        expect(cubit.state.codexApprovalsReviewer, 'auto_review');
        expect(cubit.state.codexModel, 'gpt-5.6-terra');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.medium);
        expect(cubit.state.codexSpeed, CodexSpeed.fast);

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            provider: 'codex',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            approvalPolicy: 'on-request',
            approvalsReviewer: 'user',
            codexPermissionsMode: 'default',
            sandboxMode: 'workspace-write',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.autoReview,
        );
        expect(cubit.state.codexApprovalsReviewer, 'auto_review');

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              SystemMessage(
                subtype: 'init',
                provider: 'codex',
                permissionMode: 'acceptEdits',
                executionMode: 'default',
                approvalPolicy: 'on-request',
                approvalsReviewer: 'user',
                codexPermissionsMode: 'default',
                sandboxMode: 'workspace-write',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.autoReview,
        );
        expect(cubit.state.codexApprovalsReviewer, 'auto_review');
      },
    );

    test(
      'unknown old Bridge can request Plan but an explicit refusal rolls it back',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        expect(cubit.state.codexPermissionStateKnown, isFalse);
        cubit.setSessionModes(planMode: true);
        expect(cubit.state.planMode, isTrue);
        expect(mockBridge.sentMessages.single.type, 'set_permission_mode');
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload, isNot(contains('approvalPolicy')));
        expect(payload, isNot(contains('approvalsReviewer')));
        expect(payload, isNot(contains('codexPermissionsMode')));

        mockBridge.emitMessage(
          const ErrorMessage(
            message: 'Native Codex Plan mode is unavailable.',
            errorCode: 'codex_native_plan_mode_unsupported',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.planMode, isFalse);
        expect(cubit.state.inPlanMode, isFalse);
        expect(cubit.state.codexPermissionStateKnown, isFalse);
        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.unsupported,
        );
      },
    );

    test(
      'inconclusive native Plan probe rolls back without caching unsupported',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        cubit.setSessionModes(planMode: true);
        mockBridge.emitMessage(
          const ErrorMessage(
            message: 'Plan capability probe was inconclusive.',
            errorCode: 'codex_native_plan_mode_probe_retry',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.planMode, isFalse);
        expect(cubit.state.inPlanMode, isFalse);
        expect(
          cubit.state.codexNativePlanModeSupport,
          CodexNativePlanModeSupport.unknown,
        );

        cubit.setSessionModes(planMode: true);
        expect(cubit.state.planMode, isTrue);
        expect(mockBridge.sentMessages, hasLength(2));
      },
    );

    test(
      'sandbox-only metadata does not fabricate a known Codex approval policy',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            provider: 'codex',
            sandboxMode: 'danger-full-access',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.sandboxMode, SandboxMode.off);
        expect(cubit.state.codexPermissionStateKnown, isFalse);
      },
    );

    test('explicitly unsupported Codex runtime blocks Plan optimism', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      mockBridge.emitSessions([
        const SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
          codexNativePlanModeSupported: false,
        ),
      ]);
      await Future.microtask(() {});

      cubit.setSessionModes(planMode: true);

      expect(cubit.state.planMode, isFalse);
      expect(mockBridge.sentMessages, isEmpty);
    });

    test('status message updates state.status', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const StatusMessage(status: ProcessStatus.running),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.status, ProcessStatus.running);
    });

    test(
      'Codex Desktop continuity watches the bound thread and preserves queue semantics',
      () async {
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final watch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final watchJson = jsonDecode(watch.toJson()) as Map<String, dynamic>;
        final requestId = watchJson['requestId'] as String;
        expect(watchJson, containsPair('sessionId', 's1'));
        expect(watchJson, containsPair('threadId', 'thread-1'));

        final historyRequestsBeforeReady =
            mockBridge.requestSessionHistoryCallCount;
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'turn-desktop',
            turnSteerable: true,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.externalDesktopTurnActive, isTrue);
        expect(cubit.externalDesktopTurnSteerable.value, isTrue);

        final messageCountBeforeExternalSettings =
            mockBridge.sentMessages.length;
        cubit.setCodexModel(
          'gpt-5.6-sol',
          reasoningEffort: ReasoningEffort.ultra,
        );
        cubit.setCodexSpeed(CodexSpeed.fast);
        expect(
          mockBridge.sentMessages.length,
          messageCountBeforeExternalSettings,
        );

        cubit.sendMessage('follow up');
        expect(mockBridge.sentMessages.last.type, 'input');

        final queued = QueuedInputItem(
          itemId: 'queued-1',
          text: 'follow up',
          createdAt: DateTime(2026).toIso8601String(),
        );
        mockBridge.emitMessage(
          ConversationQueueMessage(sessionId: 's1', limit: 1, items: [queued]),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.queuedInput?.itemId, 'queued-1');

        cubit.steerQueuedInput(queued);
        final steerMessage = mockBridge.sentMessages.last;
        final steerJson =
            jsonDecode(steerMessage.toJson()) as Map<String, dynamic>;
        expect(steerJson['type'], 'steer_queued_input');
        expect(steerJson['expectedTurnId'], 'turn-desktop');
        expect(steerMessage.delivery, ClientMessageDelivery.ephemeral);

        mockBridge.emitMessage(
          const ErrorMessage(
            message:
                'This Desktop turn is owned by another app-server connection.',
            errorCode: 'external_turn_not_steerable',
            sessionId: 's1',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.queuedInput?.itemId, 'queued-1');
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().where(
            (entry) =>
                entry.message is ErrorMessage &&
                (entry.message as ErrorMessage).errorCode ==
                    'external_turn_not_steerable',
          ),
          hasLength(1),
        );

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.externalDesktopTurnSteerable.value, isFalse);
        final messageCountBeforeAmbiguousSteer = mockBridge.sentMessages.length;
        cubit.steerQueuedInput(queued);
        expect(
          mockBridge.sentMessages.length,
          messageCountBeforeAmbiguousSteer,
        );

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'turn-desktop',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.externalDesktopTurnSteerable.value, isFalse);
        final messageCountBeforeUnownedSteer = mockBridge.sentMessages.length;
        cubit.steerQueuedInput(queued);
        expect(mockBridge.sentMessages.length, messageCountBeforeUnownedSteer);

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.message,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            turnId: 'turn-desktop',
            itemKey: 'assistant:desktop-1',
            payload: const AssistantServerMessage(
              message: AssistantMessage(
                id: 'desktop-1',
                role: 'assistant',
                content: [TextContent(text: 'Desktop progress')],
                model: 'codex',
              ),
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.message,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            turnId: 'turn-desktop',
            itemKey: 'tool-start:desktop-tool-1',
            payload: const AssistantServerMessage(
              message: AssistantMessage(
                id: 'desktop-tool-1',
                role: 'assistant',
                content: [
                  ToolUseContent(
                    id: 'desktop-tool-1',
                    name: 'exec',
                    input: {'command': 'inspect'},
                  ),
                ],
                model: 'codex',
              ),
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.message,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            turnId: 'turn-desktop',
            itemKey: 'tool-result:desktop-tool-1',
            payload: const ToolResultMessage(
              toolUseId: 'desktop-tool-1',
              toolName: 'exec',
              content: 'inspection complete',
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.queuedInput?.itemId, 'queued-1');
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().any(
            (entry) =>
                entry.message is AssistantServerMessage &&
                (entry.message as AssistantServerMessage).message.id ==
                    'desktop-1',
          ),
          isTrue,
        );
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().any(
            (entry) =>
                entry.message is AssistantServerMessage &&
                (entry.message as AssistantServerMessage).message.content.any(
                  (content) =>
                      content is ToolUseContent &&
                      content.id == 'desktop-tool-1',
                ),
          ),
          isTrue,
        );
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().any(
            (entry) =>
                entry.message is ToolResultMessage &&
                (entry.message as ToolResultMessage).toolUseId ==
                    'desktop-tool-1',
          ),
          isTrue,
        );

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.idle,
            turnId: 'turn-desktop',
            outcome: 'completed',
            historyReady: true,
            handoffQueued: true,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.queuedInput?.itemId, 'queued-1');
        expect(
          mockBridge.requestSessionHistoryCallCount,
          historyRequestsBeforeReady + 1,
        );
      },
    );

    test(
      'Codex conversation restores Home-screen continuity before taking over',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
            externalDesktopTurnActive: true,
          ),
        ];
        mockBridge.cachedMessagesBySession['s1'] = const [
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'desktop-cached',
              role: 'assistant',
              content: [TextContent(text: 'Cached Desktop progress')],
              model: 'codex',
            ),
          ),
        ];
        mockBridge.recordBackgroundDesktopContinuity(
          const CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.watching,
            requestId: 'list-watch',
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'desktop-turn',
          ),
        );
        mockBridge.recordBackgroundDesktopContinuity(
          const CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.message,
            requestId: 'list-watch',
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            turnId: 'desktop-turn',
            itemKey: 'thinking-home-1',
            payload: ThinkingDeltaMessage(text: 'Background reasoning'),
          ),
        );

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.externalDesktopTurnActive, isTrue);
        expect(streamingCubit.state.thinking, 'Background reasoning');
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().any(
            (entry) =>
                entry.message is AssistantServerMessage &&
                (entry.message as AssistantServerMessage).message.id ==
                    'desktop-cached',
          ),
          isTrue,
        );

        final watch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final requestId =
            (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
                as String;
        mockBridge.recordBackgroundDesktopContinuity(
          const CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.message,
            requestId: 'list-watch',
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            turnId: 'desktop-turn',
            itemKey: 'thinking-home-2',
            payload: ThinkingDeltaMessage(text: ' tail'),
          ),
        );
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.watching,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'desktop-turn',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(streamingCubit.state.thinking, 'Background reasoning tail');

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.message,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            turnId: 'desktop-turn',
            itemKey: 'thinking-home-1',
            payload: const ThinkingDeltaMessage(text: ' duplicate'),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(streamingCubit.state.thinking, 'Background reasoning tail');
      },
    );

    test('Codex conversation ignores future continuity semantics', () async {
      final cubit = createCubit(
        's1',
        provider: Provider.codex,
        initialProjectPath: '/project',
      );
      addTearDown(cubit.close);
      mockBridge.emitMessage(
        const SystemMessage(
          subtype: 'init',
          sessionId: 'thread-1',
          provider: 'codex',
          projectPath: '/project',
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      final watch = mockBridge.sentMessages.lastWhere(
        (message) => message.type == 'codex_desktop_continuity_watch',
      );
      final requestId =
          (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
              as String;

      mockBridge.emitLocalFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.state,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 's1',
          threadId: 'thread-1',
          origin: 'desktop_live_v2',
          state: CodexDesktopContinuityState.running,
          turnId: 'future-turn',
        ),
        sessionId: 's1',
      );
      mockBridge.emitLocalFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.unknown,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 's1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
        ),
        sessionId: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.externalDesktopTurnActive, isFalse);

      mockBridge.emitLocalFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.state,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 's1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          state: CodexDesktopContinuityState.running,
          turnId: 'desktop-turn',
        ),
        sessionId: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.externalDesktopTurnActive, isTrue);
      expect(cubit.state.externalDesktopTurnId, 'desktop-turn');
    });

    test(
      'Codex Desktop continuity stays disabled on an older Bridge',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {};
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        mockBridge.emitSessions(const []);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'codex_desktop_continuity_watch',
          ),
          isEmpty,
        );
      },
    );

    test(
      'Codex Desktop continuity binds from session_list before history and stays stable',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        List<ClientMessage> sent(String type) => mockBridge.sentMessages
            .where((message) => message.type == type)
            .toList();

        expect(cubit.state.claudeSessionId, 'thread-1');
        expect(cubit.state.projectPath, '/project');
        expect(sent('codex_desktop_continuity_watch'), hasLength(1));
        expect(sent('codex_desktop_continuity_unwatch'), isEmpty);
        final watchJson =
            jsonDecode(sent('codex_desktop_continuity_watch').single.toJson())
                as Map<String, dynamic>;
        expect(watchJson, containsPair('threadId', 'thread-1'));

        mockBridge.emitSessions(mockBridge.sessionSnapshot);
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'session_created',
            sessionId: 'bridge-runtime-id',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(cubit.state.claudeSessionId, 'thread-1');
        expect(sent('codex_desktop_continuity_watch'), hasLength(1));
        expect(sent('codex_desktop_continuity_unwatch'), isEmpty);
      },
    );

    test(
      'Codex session snapshot survives stale cached history on first open',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        mockBridge.cachedMessagesBySession['s1'] = const [
          SystemMessage(
            subtype: 'session_created',
            provider: 'codex',
            sessionId: 'bridge-runtime-id',
            projectPath: '/project',
          ),
          StatusMessage(status: ProcessStatus.idle),
        ];

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});
        await Future.microtask(() {});

        final watches = mockBridge.sentMessages
            .where(
              (message) => message.type == 'codex_desktop_continuity_watch',
            )
            .toList();
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.claudeSessionId, 'thread-1');
        expect(watches, hasLength(1));
        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'codex_desktop_continuity_unwatch',
          ),
          isEmpty,
        );

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [StatusMessage(status: ProcessStatus.idle)],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.running);
      },
    );

    test(
      'Codex session snapshot remains status authority over cached and live history',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        mockBridge.cachedMessagesBySession['s1'] = const [
          StatusMessage(status: ProcessStatus.running),
        ];

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.idle);

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [StatusMessage(status: ProcessStatus.running)],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.idle);

        final watch = mockBridge.sentMessages.singleWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final requestId =
            (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
                as String;
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'turn-1',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.externalDesktopTurnActive, isTrue);
      },
    );

    test(
      'Codex session snapshot keeps identity and config above stale history',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project-new',
            claudeSessionId: 'thread-new',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'fast',
          ),
        ];
        mockBridge.cachedMessagesBySession['s1'] = const [
          SystemMessage(
            subtype: 'init',
            provider: 'codex',
            sessionId: 'thread-old',
            projectPath: '/project-old',
            model: 'gpt-5.4',
            modelReasoningEffort: 'high',
            serviceTier: 'standard',
          ),
        ];

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.claudeSessionId, 'thread-new');
        expect(cubit.state.projectPath, '/project-new');
        expect(cubit.state.codexModel, 'gpt-5.6-sol');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
        expect(cubit.state.codexSpeed, CodexSpeed.fast);

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              SystemMessage(
                subtype: 'init',
                provider: 'codex',
                sessionId: 'thread-older',
                projectPath: '/project-older',
                model: 'gpt-5.3-codex',
                modelReasoningEffort: 'medium',
                serviceTier: 'standard',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.claudeSessionId, 'thread-new');
        expect(cubit.state.projectPath, '/project-new');
        expect(cubit.state.codexModel, 'gpt-5.6-sol');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
        expect(cubit.state.codexSpeed, CodexSpeed.fast);
        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'codex_desktop_continuity_watch',
          ),
          hasLength(1),
        );
        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'codex_desktop_continuity_unwatch',
          ),
          isEmpty,
        );
      },
    );

    test(
      'first Codex snapshot takes status authority from history fallback',
      () async {
        mockBridge.cachedMessagesBySession['s1'] = const [
          StatusMessage(status: ProcessStatus.running),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.running);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.idle);
      },
    );

    test(
      'first Codex snapshot does not overwrite a live running status',
      () async {
        mockBridge.cachedMessagesBySession['s1'] = const [
          StatusMessage(status: ProcessStatus.running),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.running),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.running);
      },
    );

    test('Claude history can still settle a running status', () async {
      final cubit = createCubit('s1', provider: Provider.claude);
      addTearDown(cubit.close);

      mockBridge.emitMessage(
        const StatusMessage(status: ProcessStatus.running),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(cubit.state.status, ProcessStatus.running);

      mockBridge.emitMessage(
        const HistoryMessage(
          messages: [StatusMessage(status: ProcessStatus.idle)],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.status, ProcessStatus.idle);
    });

    test('Codex history remains status fallback without SessionInfo', () async {
      mockBridge.cachedMessagesBySession['s1'] = const [
        StatusMessage(status: ProcessStatus.running),
      ];
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});
      expect(cubit.state.status, ProcessStatus.running);

      mockBridge.emitMessage(
        const HistoryMessage(
          messages: [StatusMessage(status: ProcessStatus.idle)],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.status, ProcessStatus.idle);
    });

    test(
      'old Bridge session snapshots can settle their own running baseline',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {};
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.running);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.idle);
      },
    );

    test(
      'snapshot authority resets when reconnecting to an older Bridge',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project-new',
            claudeSessionId: 'thread-new',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'fast',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.running);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        await Future.microtask(() {});
        mockBridge.advertisedBridgeCapabilities = const {};
        mockBridge.emitConnection(BridgeConnectionState.connected);
        await Future.microtask(() {});
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              SystemMessage(
                subtype: 'init',
                provider: 'codex',
                sessionId: 'thread-old',
                projectPath: '/project-old',
                model: 'gpt-5.4',
                modelReasoningEffort: 'medium',
                serviceTier: 'standard',
              ),
              StatusMessage(status: ProcessStatus.idle),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.idle);
        expect(cubit.state.claudeSessionId, 'thread-old');
        expect(cubit.state.projectPath, '/project-old');
        expect(cubit.state.codexModel, 'gpt-5.4');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.medium);
        expect(cubit.state.codexSpeed, CodexSpeed.standard);
      },
    );

    test(
      'rapid reconnect consumes the first authoritative session snapshot',
      () async {
        mockBridge.advertisedBridgeCapabilities = const {};
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project-old',
            claudeSessionId: 'thread-old',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexModel: 'gpt-5.4',
          ),
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});
        expect(cubit.state.claudeSessionId, 'thread-old');

        // These broadcasts intentionally cross separate controllers without
        // yielding. BridgeService's global generation has already advanced by
        // the time the queued disconnect callback runs.
        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        mockBridge.emitConnection(BridgeConnectionState.connected);
        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project-new',
            claudeSessionId: 'thread-new',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'fast',
          ),
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.claudeSessionId, 'thread-new');
        expect(cubit.state.projectPath, '/project-new');
        expect(cubit.state.codexModel, 'gpt-5.6-sol');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
        expect(cubit.state.codexSpeed, CodexSpeed.fast);
      },
    );

    test(
      'Codex session snapshot hydrates the complete toolbar config',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            permissionMode: 'bypassPermissions',
            executionMode: 'fullAccess',
            planMode: false,
            codexApprovalPolicy: 'never',
            codexApprovalsReviewer: 'user',
            codexPermissionsMode: 'fullAccess',
            codexSandboxMode: 'danger-full-access',
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'fast',
          ),
        ];

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
        expect(cubit.state.executionMode, ExecutionMode.fullAccess);
        expect(cubit.state.codexPermissionStateKnown, isTrue);
        expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.never);
        expect(cubit.state.codexApprovalsReviewer, 'user');
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.fullAccess,
        );
        expect(cubit.state.sandboxMode, SandboxMode.off);
        expect(cubit.state.planMode, isFalse);
        expect(cubit.state.codexModel, 'gpt-5.6-sol');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
        expect(cubit.state.codexSpeed, CodexSpeed.fast);
      },
    );

    test(
      'legacy-only full access snapshot also restores never approval',
      () async {
        mockBridge.sessionSnapshot = [
          SessionInfo.fromJson(const {
            'id': 's1',
            'provider': 'codex',
            'projectPath': '/project',
            'claudeSessionId': 'thread-1',
            'status': 'idle',
            'permissionMode': 'bypassPermissions',
          }),
        ];

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
        expect(cubit.state.executionMode, ExecutionMode.fullAccess);
        expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.never);
      },
    );

    test('sparse old-Bridge snapshots preserve known Codex config', () async {
      mockBridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          claudeSessionId: 'thread-1',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
          permissionMode: 'bypassPermissions',
          executionMode: 'fullAccess',
          codexApprovalPolicy: 'never',
          codexApprovalsReviewer: 'user',
          codexPermissionsMode: 'fullAccess',
          codexSandboxMode: 'danger-full-access',
          codexModel: 'gpt-5.6-terra',
          codexModelReasoningEffort: 'xhigh',
          codexServiceTier: 'fast',
        ),
      ];
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitSessions(const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          claudeSessionId: 'thread-1',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
        ),
      ]);
      await Future.microtask(() {});

      expect(cubit.state.executionMode, ExecutionMode.fullAccess);
      expect(cubit.state.codexPermissionStateKnown, isTrue);
      expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.never);
      expect(cubit.state.codexPermissionsMode, CodexPermissionsMode.fullAccess);
      expect(cubit.state.codexApprovalsReviewer, 'user');
      expect(cubit.state.sandboxMode, SandboxMode.off);
      expect(cubit.state.codexModel, 'gpt-5.6-terra');
      expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.xhigh);
      expect(cubit.state.codexSpeed, CodexSpeed.fast);

      mockBridge.emitSessions(const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          claudeSessionId: 'thread-1',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
          executionMode: 'default',
          codexApprovalsReviewer: 'auto_review',
          codexSandboxMode: 'workspace-write',
        ),
      ]);
      await Future.microtask(() {});

      expect(cubit.state.executionMode, ExecutionMode.fullAccess);
      expect(cubit.state.codexPermissionStateKnown, isTrue);
      expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.never);
      expect(cubit.state.codexPermissionsMode, CodexPermissionsMode.custom);
      expect(cubit.state.codexApprovalsReviewer, 'auto_review');
      expect(cubit.state.sandboxMode, SandboxMode.on);
    });

    test(
      'unknown bootstrap snapshot preserves initial Codex full access',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'starting',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        final cubit = ChatSessionCubit(
          sessionId: 's1',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          initialPermissionMode: PermissionMode.bypassPermissions,
          initialSandboxMode: SandboxMode.off,
          initialCodexApprovalPolicy: CodexApprovalPolicy.never,
          initialCodexApprovalsReviewer: 'user',
          initialCodexPermissionsMode: CodexPermissionsMode.fullAccess,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
        expect(cubit.state.executionMode, ExecutionMode.fullAccess);
        expect(cubit.state.codexPermissionStateKnown, isTrue);
        expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.never);
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.fullAccess,
        );
        expect(cubit.state.sandboxMode, SandboxMode.off);
      },
    );

    test(
      'pending next-turn permissions fence stale session snapshots',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            codexApprovalPolicy: 'on-request',
            codexApprovalsReviewer: 'user',
            codexPermissionsMode: 'default',
            codexSandboxMode: 'workspace-write',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.setCodexPermissionsMode(
          CodexPermissionsMode.fullAccess,
          applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        );
        final permissionChangeId =
            (jsonDecode(mockBridge.sentMessages.last.toJson())
                    as Map<String, dynamic>)['permissionChangeId']
                as String;
        mockBridge.emitSessions(mockBridge.sessionSnapshot);
        await Future.microtask(() {});

        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.fullAccess,
        );
        expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.never);
        expect(cubit.state.sandboxMode, SandboxMode.off);

        mockBridge.emitMessage(
          SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'bypassPermissions',
            executionMode: 'fullAccess',
            approvalPolicy: 'never',
            approvalsReviewer: 'user',
            codexPermissionsMode: 'fullAccess',
            sandboxMode: 'danger-full-access',
            planMode: false,
            permissionChangeId: permissionChangeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.isPermissionChangePending, isFalse);

        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            codexApprovalPolicy: 'on-request',
            codexApprovalsReviewer: 'auto_review',
            codexPermissionsMode: 'autoReview',
            codexSandboxMode: 'workspace-write',
          ),
        ]);
        await Future.microtask(() {});

        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.autoReview,
        );
        expect(cubit.state.codexApprovalsReviewer, 'auto_review');
        expect(cubit.state.sandboxMode, SandboxMode.on);
      },
    );

    test(
      'duplicate connected notifications do not churn continuity watches',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        int sentCount(String type) => mockBridge.sentMessages
            .where((message) => message.type == type)
            .length;
        expect(sentCount('codex_desktop_continuity_watch'), 1);

        mockBridge.emitConnection(BridgeConnectionState.connected);
        mockBridge.emitConnection(BridgeConnectionState.connected);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(sentCount('codex_desktop_continuity_watch'), 1);
        expect(sentCount('codex_desktop_continuity_unwatch'), 0);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        mockBridge.emitConnection(BridgeConnectionState.connected);
        mockBridge.emitSessions(mockBridge.sessionSnapshot);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(sentCount('codex_desktop_continuity_watch'), 2);
        expect(sentCount('codex_desktop_continuity_unwatch'), 0);
      },
    );

    test(
      'failed continuity watch can bind again from the same snapshot',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        final firstWatch = mockBridge.sentMessages.singleWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final firstRequestId =
            (jsonDecode(firstWatch.toJson())
                    as Map<String, dynamic>)['requestId']
                as String;
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.error,
            requestId: firstRequestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            errorCode: 'rollout_unavailable',
            error: 'rollout is not visible yet',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'codex_desktop_continuity_watch',
          ),
          hasLength(1),
        );

        await Future<void>.delayed(const Duration(milliseconds: 900));

        final watches = mockBridge.sentMessages
            .where(
              (message) => message.type == 'codex_desktop_continuity_watch',
            )
            .toList();
        expect(watches, hasLength(2));
        final retryRequestId =
            (jsonDecode(watches.last.toJson())
                    as Map<String, dynamic>)['requestId']
                as String;
        expect(retryRequestId, isNot(firstRequestId));
      },
    );

    test(
      'path rejection stays suppressed until the connection changes',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/blocked',
            claudeSessionId: 'thread-1',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});
        final firstWatch = mockBridge.sentMessages.singleWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final requestId =
            (jsonDecode(firstWatch.toJson())
                    as Map<String, dynamic>)['requestId']
                as String;

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.error,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            errorCode: 'path_not_allowed',
            error: 'blocked path',
          ),
          sessionId: 's1',
        );
        mockBridge.emitSessions(const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/blocked',
            claudeSessionId: 'thread-1',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        int watchCount() => mockBridge.sentMessages
            .where(
              (message) => message.type == 'codex_desktop_continuity_watch',
            )
            .length;
        expect(watchCount(), 1);
        expect(cubit.state.status, ProcessStatus.idle);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        mockBridge.emitConnection(BridgeConnectionState.connected);
        mockBridge.emitSessions(mockBridge.sessionSnapshot);
        await Future.microtask(() {});
        await Future.microtask(() {});
        expect(watchCount(), 2);
      },
    );

    test('watching idle settles a stale running session snapshot', () async {
      mockBridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          claudeSessionId: 'thread-1',
          status: 'running',
          createdAt: '',
          lastActivityAt: '',
        ),
      ];
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});
      final watch = mockBridge.sentMessages.singleWhere(
        (message) => message.type == 'codex_desktop_continuity_watch',
      );
      final requestId =
          (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
              as String;

      mockBridge.emitLocalFeature(
        CodexDesktopContinuityEventMessage(
          event: CodexDesktopContinuityEventKind.watching,
          requestId: requestId,
          bridgeInstanceId: 'bridge-1',
          sessionId: 's1',
          threadId: 'thread-1',
          origin: 'desktop_rollout',
          state: CodexDesktopContinuityState.idle,
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.status, ProcessStatus.idle);
      expect(cubit.state.externalDesktopTurnActive, isFalse);
    });

    test(
      'Codex Desktop continuity settles running state when reconnecting to an older Bridge',
      () async {
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        final watch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final requestId =
            (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
                as String;
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'desktop-turn',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.running);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        mockBridge.advertisedBridgeCapabilities = const {};
        mockBridge.emitConnection(BridgeConnectionState.connected);
        mockBridge.emitSessions([
          const SessionInfo(
            id: 's1',
            projectPath: '/project',
            status: 'idle',
            provider: 'codex',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.status, ProcessStatus.idle);
        expect(mockBridge.lastRequestedSessionId, 's1');
      },
    );

    test(
      'Codex Desktop continuity reconciles a queued handoff after downgrade to an older Bridge',
      () async {
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        final watch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final requestId =
            (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
                as String;

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'desktop-turn',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: requestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.idle,
            turnId: 'desktop-turn',
            outcome: 'completed',
            handoffQueued: true,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.status, ProcessStatus.running);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        mockBridge.advertisedBridgeCapabilities = const {};
        mockBridge.emitConnection(BridgeConnectionState.connected);
        mockBridge.emitSessions([
          const SessionInfo(
            id: 's1',
            projectPath: '/project',
            status: 'idle',
            provider: 'codex',
            createdAt: '',
            lastActivityAt: '',
          ),
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.status, ProcessStatus.idle);
        expect(mockBridge.lastRequestedSessionId, 's1');
      },
    );

    test(
      'Desktop reasoning is incremental and stale continuity bindings are ignored',
      () async {
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        final watch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final requestId =
            (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
                as String;

        CodexDesktopContinuityEventMessage reasoning(String id) =>
            CodexDesktopContinuityEventMessage(
              event: CodexDesktopContinuityEventKind.message,
              requestId: id,
              bridgeInstanceId: 'bridge-1',
              sessionId: 's1',
              threadId: 'thread-1',
              origin: 'desktop_rollout',
              itemKey: 'reasoning:1',
              payload: const ThinkingDeltaMessage(text: 'Inspecting\n'),
            );

        mockBridge.emitLocalFeature(reasoning('stale'), sessionId: 's1');
        await Future.microtask(() {});
        expect(streamingCubit.state.thinking, isEmpty);

        mockBridge.emitLocalFeature(reasoning(requestId), sessionId: 's1');
        mockBridge.emitLocalFeature(reasoning(requestId), sessionId: 's1');
        await Future.microtask(() {});
        expect(streamingCubit.state.thinking, 'Inspecting\n');
      },
    );

    test(
      'Desktop reasoning stays isolated by explicit turn identity',
      () async {
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        final watch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final requestId =
            (jsonDecode(watch.toJson()) as Map<String, dynamic>)['requestId']
                as String;

        void emitDesktop({
          required String turnId,
          required String itemKey,
          required ServerMessage payload,
        }) {
          mockBridge.emitLocalFeature(
            CodexDesktopContinuityEventMessage(
              event: CodexDesktopContinuityEventKind.message,
              requestId: requestId,
              bridgeInstanceId: 'bridge-1',
              sessionId: 's1',
              threadId: 'thread-1',
              origin: 'desktop_rollout',
              turnId: turnId,
              itemKey: itemKey,
              payload: payload,
            ),
            sessionId: 's1',
          );
        }

        emitDesktop(
          turnId: 'turn-a',
          itemKey: 'reasoning:a',
          payload: const ThinkingDeltaMessage(text: 'Reasoning A'),
        );
        await Future.microtask(() {});
        expect(streamingCubit.state.thinking, 'Reasoning A');

        emitDesktop(
          turnId: 'turn-b',
          itemKey: 'reasoning:b',
          payload: const ThinkingDeltaMessage(text: 'Reasoning B'),
        );
        await Future.microtask(() {});
        expect(streamingCubit.state.thinking, 'Reasoning B');

        // A can complete while B remains the visible streaming turn. Its
        // assistant must not clear B's live indicator or steal B's reasoning.
        emitDesktop(
          turnId: 'turn-a',
          itemKey: 'assistant:a',
          payload: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-a',
              role: 'assistant',
              content: [TextContent(text: 'Answer A')],
              model: 'codex',
            ),
          ),
        );
        await Future.microtask(() {});
        expect(streamingCubit.state.thinking, 'Reasoning B');

        emitDesktop(
          turnId: 'turn-b',
          itemKey: 'assistant:b',
          payload: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-b',
              role: 'assistant',
              content: [TextContent(text: 'Answer B')],
              model: 'codex',
            ),
          ),
        );
        await Future.microtask(() {});

        AssistantServerMessage assistant(String id) =>
            (cubit.state.entries
                    .whereType<ServerChatEntry>()
                    .firstWhere(
                      (entry) =>
                          entry.message is AssistantServerMessage &&
                          (entry.message as AssistantServerMessage)
                                  .message
                                  .id ==
                              id,
                    )
                    .message
                as AssistantServerMessage);
        final assistantA = assistant('assistant-a').message;
        final assistantB = assistant('assistant-b').message;
        expect(
          assistantA.content.whereType<ThinkingContent>().single.thinking,
          'Reasoning A',
        );
        expect(
          assistantB.content.whereType<ThinkingContent>().single.thinking,
          'Reasoning B',
        );
      },
    );

    test(
      'Desktop continuity reconciles an offline completion without losing handoff state',
      () async {
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/project',
        );
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'init',
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        final firstWatch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final firstRequestId =
            (jsonDecode(firstWatch.toJson())
                    as Map<String, dynamic>)['requestId']
                as String;
        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.state,
            requestId: firstRequestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.running,
            turnId: 'turn-desktop',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.externalDesktopTurnActive, isTrue);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        await Future.microtask(() {});
        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.status, ProcessStatus.running);

        mockBridge.emitConnection(BridgeConnectionState.connected);
        mockBridge.emitSessions(mockBridge.sessionSnapshot);
        await Future.microtask(() {});
        final reconnectWatch = mockBridge.sentMessages.lastWhere(
          (message) => message.type == 'codex_desktop_continuity_watch',
        );
        final reconnectRequestId =
            (jsonDecode(reconnectWatch.toJson())
                    as Map<String, dynamic>)['requestId']
                as String;
        expect(reconnectRequestId, isNot(firstRequestId));

        mockBridge.emitLocalFeature(
          CodexDesktopContinuityEventMessage(
            event: CodexDesktopContinuityEventKind.watching,
            requestId: reconnectRequestId,
            bridgeInstanceId: 'bridge-1',
            sessionId: 's1',
            threadId: 'thread-1',
            origin: 'desktop_rollout',
            state: CodexDesktopContinuityState.idle,
            turnId: 'turn-desktop',
            handoffQueued: true,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.externalDesktopTurnActive, isFalse);
        expect(cubit.state.status, ProcessStatus.running);
      },
    );

    test(
      'initial project path is available before bridge metadata arrives',
      () {
        final cubit = createCubit(
          's1',
          initialProjectPath: '/Users/me/Workspace/ccpocket',
        );
        addTearDown(cubit.close);

        expect(cubit.state.projectPath, '/Users/me/Workspace/ccpocket');
      },
    );

    test('system message updates project path metadata', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const SystemMessage(
          subtype: 'session_created',
          projectPath: '/Users/me/Workspace/ccpocket',
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.projectPath, '/Users/me/Workspace/ccpocket');
    });

    test('history message restores project path metadata', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const HistoryMessage(
          messages: [
            SystemMessage(
              subtype: 'session_created',
              projectPath: '/Users/me/Workspace/ccpocket',
            ),
            StatusMessage(status: ProcessStatus.idle),
          ],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.projectPath, '/Users/me/Workspace/ccpocket');
    });

    test(
      'codex explicit execution mode wins over legacy permission mode',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            planMode: false,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.executionMode, ExecutionMode.defaultMode);
        expect(cubit.state.planMode, isFalse);
      },
    );

    test(
      'codex initial on-failure approval policy falls back to on-request',
      () {
        final cubit = ChatSessionCubit(
          sessionId: 's1',
          provider: Provider.codex,
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          initialPermissionMode: PermissionMode.acceptEdits,
          initialCodexApprovalPolicy: CodexApprovalPolicy.onFailure,
        );
        addTearDown(cubit.close);

        expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
      },
    );

    test('codex auto review mode sends on-request with auto reviewer', () {
      final cubit = ChatSessionCubit(
        sessionId: 's1',
        provider: Provider.codex,
        bridge: mockBridge,
        streamingCubit: streamingCubit,
        initialPermissionMode: PermissionMode.acceptEdits,
      );
      addTearDown(cubit.close);

      cubit.setCodexApprovalPolicy(
        CodexApprovalPolicy.onRequest,
        approvalsReviewer: 'auto_review',
      );

      expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
      expect(cubit.state.codexApprovalsReviewer, 'auto_review');
      final payload =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(payload['approvalPolicy'], 'on-request');
      expect(payload['approvalsReviewer'], 'auto_review');
    });

    test(
      'codex sandbox-only system message does not reset execution mode',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'bypassPermissions',
            executionMode: 'fullAccess',
            planMode: false,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.executionMode, ExecutionMode.fullAccess);

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'session_created',
            provider: 'codex',
            sandboxMode: 'off',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.executionMode, ExecutionMode.fullAccess);
        expect(cubit.state.planMode, isFalse);
      },
    );

    test('permission request sets approval state', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      const permMsg = PermissionRequestMessage(
        toolUseId: 'tool-1',
        toolName: 'bash',
        input: {'command': 'ls'},
      );
      mockBridge.emitMessage(permMsg, sessionId: 's1');
      await Future.microtask(() {});

      expect(cubit.state.approval, isA<ApprovalPermission>());
      final perm = cubit.state.approval as ApprovalPermission;
      expect(perm.toolUseId, 'tool-1');
      expect(perm.request.toolName, 'bash');
    });

    test(
      'runtime Plan approval survives cached and canonical idle history',
      () async {
        const pendingPlan = PermissionRequestMessage(
          toolUseId: 'runtime-plan',
          toolName: 'ExitPlanMode',
          input: {'plan': 'Implement the change'},
        );
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            claudeSessionId: 'thread-1',
            status: 'running',
            createdAt: '',
            lastActivityAt: '',
            planMode: true,
            pendingPermission: pendingPlan,
          ),
        ];
        mockBridge.cachedMessagesBySession['s1'] = const [
          StatusMessage(status: ProcessStatus.idle),
        ];

        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(
          (cubit.state.approval as ApprovalPermission).toolUseId,
          'runtime-plan',
        );

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [StatusMessage(status: ProcessStatus.idle)],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(
          (cubit.state.approval as ApprovalPermission).toolUseId,
          'runtime-plan',
        );
      },
    );

    test(
      'rejecting ExitPlanMode keeps Plan active and restores another question',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'plan',
            executionMode: 'default',
            planMode: true,
          ),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'question-before-reject',
            toolName: 'AskUserQuestion',
            input: {
              'questions': [
                {'question': 'Choose one'},
              ],
            },
          ),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'plan-to-reject',
            toolName: 'ExitPlanMode',
            input: {'plan': 'Not ready yet'},
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();

        cubit.reject('plan-to-reject', message: 'Continue planning');

        expect(cubit.state.approval, isA<ApprovalAskUser>());
        expect(
          (cubit.state.approval as ApprovalAskUser).toolUseId,
          'question-before-reject',
        );
        expect(cubit.state.planMode, isTrue);
        expect(cubit.state.inPlanMode, isTrue);
      },
    );

    test(
      'answering one question advances to the next pending approval',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'command-after-question',
            toolName: 'Bash',
            input: {'command': 'pwd'},
          ),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'question-to-answer',
            toolName: 'AskUserQuestion',
            input: {
              'questions': [
                {'question': 'Continue?'},
              ],
            },
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();

        cubit.answer('question-to-answer', 'Yes');

        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(
          (cubit.state.approval as ApprovalPermission).toolUseId,
          'command-after-question',
        );
      },
    );

    test('automatic tool result restores an earlier manual question', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      const question = PermissionRequestMessage(
        toolUseId: 'question-1',
        toolName: 'AskUserQuestion',
        input: {
          'questions': [
            {
              'id': 'choice',
              'header': 'Choice',
              'question': 'Choose one',
              'options': [
                {'label': 'A', 'description': 'Option A'},
              ],
            },
          ],
        },
      );
      const command = PermissionRequestMessage(
        toolUseId: 'command-1',
        toolName: 'Bash',
        input: {'command': 'pwd'},
      );

      mockBridge.emitMessage(question, sessionId: 's1');
      await Future.microtask(() {});
      expect(cubit.state.approval, isA<ApprovalAskUser>());

      mockBridge.emitMessage(command, sessionId: 's1');
      await Future.microtask(() {});
      expect(cubit.state.approval, isA<ApprovalPermission>());
      expect(
        (cubit.state.approval as ApprovalPermission).toolUseId,
        'command-1',
      );

      mockBridge.emitMessage(
        const ToolResultMessage(toolUseId: 'command-1', content: 'ok'),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.approval, isA<ApprovalAskUser>());
      expect((cubit.state.approval as ApprovalAskUser).toolUseId, 'question-1');
    });

    test(
      'automatic plan result exits plan mode and restores a manual question',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'plan',
            executionMode: 'default',
            planMode: true,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'question-before-plan',
            toolName: 'AskUserQuestion',
            input: {
              'questions': [
                {
                  'id': 'choice',
                  'header': 'Choice',
                  'question': 'Choose one',
                  'options': [
                    {'label': 'A', 'description': 'Option A'},
                  ],
                },
              ],
            },
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'automatic-plan',
            toolName: 'ExitPlanMode',
            input: {'plan': 'Run it'},
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(cubit.state.planMode, isTrue);
        expect(cubit.state.inPlanMode, isTrue);

        mockBridge.emitMessage(
          const ToolResultMessage(
            toolUseId: 'automatic-plan',
            content: 'Plan approved',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.approval, isA<ApprovalAskUser>());
        expect(
          (cubit.state.approval as ApprovalAskUser).toolUseId,
          'question-before-plan',
        );
        expect(cubit.state.planMode, isFalse);
        expect(cubit.state.inPlanMode, isFalse);
      },
    );

    test(
      'history success result preserves a question across automatic plan completion',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              PermissionRequestMessage(
                toolUseId: 'history-question',
                toolName: 'AskUserQuestion',
                input: {
                  'questions': [
                    {'question': 'Choose one'},
                  ],
                },
              ),
              StatusMessage(status: ProcessStatus.waitingApproval),
              ResultMessage(subtype: 'success'),
              PermissionRequestMessage(
                toolUseId: 'history-plan',
                toolName: 'ExitPlanMode',
                input: {'plan': 'Run it'},
              ),
              StatusMessage(status: ProcessStatus.waitingApproval),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const ToolResultMessage(
            toolUseId: 'history-plan',
            content: 'Plan approved',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.approval, isA<ApprovalAskUser>());
        expect(
          (cubit.state.approval as ApprovalAskUser).toolUseId,
          'history-question',
        );
      },
    );

    test('ordinary tool results do not mutate approval tracking', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const PermissionRequestMessage(
          toolUseId: 'question-stays-manual',
          toolName: 'AskUserQuestion',
          input: {
            'questions': [
              {'question': 'Choose one'},
            ],
          },
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const ToolResultMessage(toolUseId: 'ordinary-tool', content: 'done'),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.approval, isA<ApprovalAskUser>());
      expect(
        mockBridge.respondedToolUseIds('s1'),
        isNot(contains('ordinary-tool')),
      );
    });

    test('a completed older turn cannot regain approval focus', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const PermissionRequestMessage(
          toolUseId: 'old-request',
          toolName: 'Bash',
          input: {'command': 'old'},
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      mockBridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(cubit.state.approval, isA<ApprovalNone>());

      mockBridge.emitMessage(
        const PermissionRequestMessage(
          toolUseId: 'new-request',
          toolName: 'Bash',
          input: {'command': 'new'},
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      mockBridge.emitMessage(
        const ToolResultMessage(toolUseId: 'new-request', content: 'done'),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.approval, isA<ApprovalNone>());
    });

    test('sendMessage adds user entry and sends to bridge', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.sendMessage('Hello Claude');

      expect(cubit.state.entries, hasLength(1));
      expect(cubit.state.entries.first, isA<UserChatEntry>());
      final entry = cubit.state.entries.first as UserChatEntry;
      expect(entry.text, 'Hello Claude');
      expect(entry.clientMessageId, isNotNull);

      expect(mockBridge.sentMessages, hasLength(1));
      final payload =
          jsonDecode(mockBridge.sentMessages.single.toJson())
              as Map<String, dynamic>;
      expect(payload['clientMessageId'], entry.clientMessageId);
      expect(payload.containsKey('baseSeq'), isFalse);
    });

    test('plain text send remains synchronous without an image backlog', () {
      var encoderCalled = false;
      final cubit = createCubit(
        's1',
        imagePayloadEncoder: (images) async {
          encoderCalled = true;
          return const [];
        },
      );
      addTearDown(cubit.close);

      cubit.sendMessage('Immediate text');

      expect(encoderCalled, isFalse);
      expect(mockBridge.sentMessages, hasLength(1));
      expect(
        jsonDecode(mockBridge.sentMessages.single.toJson())['text'],
        'Immediate text',
      );
    });

    test(
      'an image send cannot be overtaken by a following text send',
      () async {
        final encoded = Completer<List<Map<String, String>>>();
        final cubit = createCubit(
          's1',
          imagePayloadEncoder: (_) => encoded.future,
        );
        addTearDown(cubit.close);

        cubit.sendMessage(
          'Image first',
          images: [
            (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
          ],
        );
        cubit.sendMessage('Text second');

        expect(mockBridge.sentMessages, isEmpty);

        encoded.complete(const [
          {'base64': 'AQID', 'mimeType': 'image/png'},
        ]);
        await pumpEventQueue();

        final payloads = mockBridge.sentMessages
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .toList();
        expect(payloads.map((payload) => payload['text']), [
          'Image first',
          'Text second',
        ]);
        expect(payloads.first['images'], [
          {'base64': 'AQID', 'mimeType': 'image/png'},
        ]);
      },
    );

    test(
      'image encoding failure marks the input failed without poisoning the queue',
      () async {
        final cubit = createCubit(
          's1',
          imagePayloadEncoder: (_) async => throw StateError('encode failed'),
        );
        addTearDown(cubit.close);

        cubit.sendMessage(
          'Broken image',
          images: [
            (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
          ],
        );
        cubit.sendMessage('Text after failed image');
        await pumpEventQueue();

        expect(mockBridge.sentMessages, hasLength(1));
        expect(
          jsonDecode(mockBridge.sentMessages.single.toJson())['text'],
          'Text after failed image',
        );
        final entries = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(entries, hasLength(2));
        expect(entries.first.clientMessageId, isNotNull);
        expect(entries.first.status, MessageStatus.failed);
        expect(entries.last.status, MessageStatus.sending);
      },
    );

    test(
      'canceling an offline image input prevents its delayed send',
      () async {
        mockBridge.connected = false;
        final encoded = Completer<List<Map<String, String>>>();
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          imagePayloadEncoder: (_) => encoded.future,
        );
        addTearDown(cubit.close);

        cubit.sendMessage(
          'Canceled image',
          images: [
            (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
          ],
        );
        final queued = cubit.state.queuedInput;
        expect(ChatSessionCubit.isOfflineQueuedInput(queued), isTrue);

        await cubit.cancelQueuedInput(queued!);
        encoded.complete(const [
          {'base64': 'AQID', 'mimeType': 'image/png'},
        ]);
        await pumpEventQueue();

        expect(cubit.state.queuedInput, isNull);
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test('sendMessage while disconnected queues entry with baseSeq', () async {
      mockBridge.connected = false;
      mockBridge.historySeqBySession['s1'] = 9;
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.sendMessage('Offline input');

      final entry = cubit.state.entries.single as UserChatEntry;
      expect(entry.status, MessageStatus.queued);
      expect(entry.clientMessageId, isNotNull);

      final payload =
          jsonDecode(mockBridge.sentMessages.single.toJson())
              as Map<String, dynamic>;
      expect(payload['clientMessageId'], entry.clientMessageId);
      expect(payload['baseSeq'], 9);
    });

    test(
      'codex sendMessage while disconnected uses queued input panel state',
      () async {
        mockBridge.connected = false;
        mockBridge.historySeqBySession['s1'] = 7;
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Offline Codex input');
        cubit.sendMessage('Second input is blocked');

        expect(cubit.state.entries.whereType<UserChatEntry>(), isEmpty);
        expect(cubit.state.queuedInput?.text, 'Offline Codex input');
        expect(
          ChatSessionCubit.isOfflineQueuedInput(cubit.state.queuedInput),
          isTrue,
        );
        expect(mockBridge.sentMessages, hasLength(1));

        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'input');
        expect(payload['text'], 'Offline Codex input');
        expect(payload['baseSeq'], 7);
        expect(
          ChatSessionCubit.offlineQueuedClientMessageId(
            cubit.state.queuedInput,
          ),
          payload['clientMessageId'],
        );

        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: payload['clientMessageId'] as String,
            acceptedSeq: 8,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(cubit.state.queuedInput, isNull);
        final delivered = cubit.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(delivered, hasLength(1));
        expect(delivered.single.text, 'Offline Codex input');
        expect(delivered.single.status, MessageStatus.sent);
      },
    );

    test(
      'legacy offline ack without client id preserves the queued message',
      () async {
        mockBridge.connected = false;
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Legacy offline Codex input');
        expect(cubit.state.queuedInput, isNotNull);
        expect(cubit.state.entries.whereType<UserChatEntry>(), isEmpty);

        mockBridge.emitMessage(
          const InputAckMessage(sessionId: 's1', acceptedSeq: 1),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.queuedInput, isNull);
        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Legacy offline Codex input');
        expect(users.single.status, MessageStatus.sent);
      },
    );

    test(
      'codex online input stays in its bubble when delivery ack is slow',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('Slow online Codex input');

        var users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.status, MessageStatus.sending);
        expect(cubit.state.queuedInput, isNull);

        await Future<void>.delayed(const Duration(milliseconds: 650));

        users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.status, MessageStatus.sending);
        expect(cubit.state.queuedInput, isNull);

        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: payload['clientMessageId'] as String,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.queuedInput, isNull);
        users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Slow online Codex input');
        expect(users.single.status, MessageStatus.sent);
      },
    );

    test(
      'codex online input ack before delay keeps normal message entry',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('Fast online Codex input');
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: payload['clientMessageId'] as String,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        await Future<void>.delayed(const Duration(milliseconds: 650));

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.status, MessageStatus.sent);
        expect(cubit.state.queuedInput, isNull);
      },
    );

    test(
      'codex first input sent while starting is shown when ack arrives before delay',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.starting);

        cubit.sendMessage('First Codex input while starting');

        final pendingUsers = cubit.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(pendingUsers, hasLength(1));
        expect(pendingUsers.single.status, MessageStatus.sending);
        expect(cubit.state.queuedInput, isNull);

        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: payload['clientMessageId'] as String,
            queued: false,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        await Future<void>.delayed(const Duration(milliseconds: 650));

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'First Codex input while starting');
        expect(users.single.status, MessageStatus.sent);
        expect(cubit.state.queuedInput, isNull);
      },
    );

    test(
      'codex restored user input delta does not duplicate delivery pending entry',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('Restored pending input');
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        final clientMessageId = payload['clientMessageId'] as String;

        await Future<void>.delayed(const Duration(milliseconds: 650));
        mockBridge.emitMessage(
          InputAckMessage(sessionId: 's1', clientMessageId: clientMessageId),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.queuedInput, isNull);
        expect(cubit.state.entries.whereType<UserChatEntry>(), hasLength(1));

        mockBridge.emitMessage(
          UserInputMessage(
            text: 'Restored pending input',
            clientMessageId: clientMessageId,
            timestamp: '2026-04-28T12:00:00.000Z',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Restored pending input');
        expect(users.single.status, MessageStatus.sent);
      },
    );

    test('Bridge echo upgrades the optimistic user timestamp', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      mockBridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      cubit.sendMessage('Timestamped input');
      final payload =
          jsonDecode(mockBridge.sentMessages.single.toJson())
              as Map<String, dynamic>;
      final optimistic = cubit.state.entries.whereType<UserChatEntry>().single;
      expect(optimistic.timestampIsAuthoritative, isFalse);

      final receivedAt = DateTime.parse('2026-07-25T03:04:05.678Z');
      mockBridge.emitMessage(
        ServerMessage.fromJson({
          'type': 'user_input',
          'text': 'Timestamped input',
          'clientMessageId': payload['clientMessageId'],
          'userMessageUuid': 'codex:user-turn:timestamped',
          'receivedAt': receivedAt.toIso8601String(),
        }),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      final upgraded = cubit.state.entries.whereType<UserChatEntry>().single;
      expect(upgraded.timestamp, receivedAt.toLocal());
      expect(upgraded.timestampIsAuthoritative, isTrue);
      expect(upgraded.messageUuid, 'codex:user-turn:timestamped');
    });

    test(
      'codex user_input with UUID and no local entry is displayed',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        mockBridge.emitMessage(
          const UserInputMessage(
            text: 'Message from another client',
            userMessageUuid: 'codex:user-turn:7',
            timestamp: '2026-04-28T12:00:00.000Z',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Message from another client');
        expect(users.single.status, MessageStatus.sent);
        expect(users.single.messageUuid, 'codex:user-turn:7');
      },
    );

    test(
      'duplicate codex UUID user_input does not add a second entry',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const userInput = UserInputMessage(
          text: 'Steered queued message',
          userMessageUuid: 'codex:user-turn:8',
          timestamp: '2026-04-28T12:00:00.000Z',
        );

        mockBridge.emitMessage(userInput, sessionId: 's1');
        mockBridge.emitMessage(userInput, sessionId: 's1');
        await Future.microtask(() {});

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Steered queued message');
        expect(users.single.messageUuid, 'codex:user-turn:8');
      },
    );

    test(
      'history replace keeps live tail without duplicating matched user input',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const SystemMessage(subtype: 'init', provider: 'codex'),
          sessionId: 's1',
        );
        cubit.sendMessage('History matched input');
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        final clientMessageId = payload['clientMessageId'] as String;
        mockBridge.emitMessage(
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'a1',
              role: 'assistant',
              content: [const TextContent(text: 'live tail')],
              model: 'codex',
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        mockBridge.emitMessage(
          HistoryMessage(
            messages: [
              UserInputMessage(
                text: 'History matched input',
                clientMessageId: clientMessageId,
                timestamp: '2026-04-28T12:00:00.000Z',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'History matched input');
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().where(
            (entry) => entry.message is AssistantServerMessage,
          ),
          hasLength(1),
        );
      },
    );

    test(
      'history replace keeps a live item between its canonical anchors',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const user = UserInputMessage(
          text: 'Run the check',
          userMessageUuid: 'user-anchor',
        );
        const tool = ToolResultMessage(
          toolUseId: 'tool-between-anchors',
          toolName: 'Read',
          content: 'live tool result',
        );
        const assistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-anchor',
            role: 'assistant',
            content: [TextContent(text: 'Finished')],
            model: 'codex',
          ),
          messageUuid: 'assistant-anchor-uuid',
        );

        mockBridge.emitMessage(user, sessionId: 's1');
        mockBridge.emitMessage(tool, sessionId: 's1');
        mockBridge.emitMessage(assistant, sessionId: 's1');
        await pumpEventQueue();

        List<String> visibleOrder() => cubit.state.entries
            .map((entry) {
              if (entry is UserChatEntry &&
                  entry.messageUuid == 'user-anchor') {
                return 'user';
              }
              if (entry is ServerChatEntry) {
                final message = entry.message;
                if (message is ToolResultMessage &&
                    message.toolUseId == 'tool-between-anchors') {
                  return 'tool';
                }
                if (message is AssistantServerMessage &&
                    message.message.id == 'assistant-anchor') {
                  return 'assistant';
                }
              }
              return '';
            })
            .where((label) => label.isNotEmpty)
            .toList(growable: false);

        // The first canonical snapshot has not materialized the tool result
        // yet. It must not move the already observed result after the reply.
        mockBridge.emitMessage(
          const HistoryMessage(messages: [user, assistant]),
          sessionId: 's1',
        );
        await pumpEventQueue();
        expect(visibleOrder(), ['user', 'tool', 'assistant']);

        // Once canonical history catches up, it replaces the live item at the
        // same stable position rather than duplicating it.
        mockBridge.emitMessage(
          const HistoryMessage(messages: [user, tool, assistant]),
          sessionId: 's1',
        );
        await pumpEventQueue();
        expect(visibleOrder(), ['user', 'tool', 'assistant']);
        expect(
          cubit.state.entries.whereType<ServerChatEntry>().where(
            (entry) =>
                entry.message is ToolResultMessage &&
                (entry.message as ToolResultMessage).toolUseId ==
                    'tool-between-anchors',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'large same-text live tails reconcile without quadratic alias scans',
      () async {
        const count = 3000;
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        final previous = List<ServerMessage>.generate(
          count,
          (index) => UserInputMessage(
            text: 'Repeated prompt',
            userMessageUuid: 'previous-user-$index',
          ),
          growable: false,
        );
        final canonical = List<ServerMessage>.generate(
          count,
          (index) => UserInputMessage(
            text: 'Repeated prompt',
            userMessageUuid: 'canonical-user-$index',
          ),
          growable: false,
        );

        for (final message in previous) {
          mockBridge.emitMessage(message, sessionId: 's1');
        }
        await pumpEventQueue();
        expect(
          cubit.state.entries.whereType<UserChatEntry>(),
          hasLength(count),
        );
        final stopwatch = Stopwatch()..start();
        mockBridge.emitMessage(
          HistoryMessage(messages: canonical),
          sessionId: 's1',
        );
        await pumpEventQueue();
        stopwatch.stop();

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(count + 1));
        expect(
          users
              .map((entry) => entry.messageUuid)
              .whereType<String>()
              .where((uuid) => uuid.startsWith('canonical-user-'))
              .toSet(),
          hasLength(count),
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 10)),
          reason:
              'A weak-key collision bucket must not rescan every stable user.',
        );
      },
    );

    test(
      'repeated provisional assistants and results consume weak aliases once',
      () async {
        const count = 300;
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        final previous = <ServerMessage>[
          for (var index = 0; index < count; index++)
            AssistantServerMessage(
              message: AssistantMessage(
                id: 'provisional-$index',
                role: 'assistant',
                content: const [TextContent(text: 'Shared response')],
                model: 'codex',
              ),
            ),
          for (var index = 0; index < count; index++)
            const ResultMessage(subtype: 'success'),
        ];
        final canonical = <ServerMessage>[
          for (var index = 0; index < count; index++)
            AssistantServerMessage(
              messageUuid: 'canonical-assistant-$index',
              message: AssistantMessage(
                id: 'canonical-$index',
                role: 'assistant',
                content: const [TextContent(text: 'Shared response')],
                model: 'codex',
              ),
            ),
          for (var index = 0; index < count; index++)
            const ResultMessage(subtype: 'success'),
        ];

        mockBridge.emitMessage(
          HistoryMessage(messages: previous),
          sessionId: 's1',
        );
        await pumpEventQueue();
        mockBridge.emitMessage(
          HistoryMessage(messages: canonical),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final serverMessages = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .toList(growable: false);
        expect(
          serverMessages.whereType<AssistantServerMessage>(),
          hasLength(count),
        );
        expect(serverMessages.whereType<ResultMessage>(), hasLength(count));
      },
    );

    test(
      'history replace keeps completed live assistant missing from snapshot',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const result = ResultMessage(subtype: 'success', sessionId: 'thread-1');
        final assistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: const [TextContent(text: 'Completed live response')],
            model: 'codex',
          ),
        );

        mockBridge.emitMessage(
          const StreamDeltaMessage(text: 'Completed live response'),
          sessionId: 's1',
        );
        mockBridge.emitMessage(assistant, sessionId: 's1');
        mockBridge.emitMessage(result, sessionId: 's1');
        await pumpEventQueue();

        mockBridge.emitMessage(
          const HistoryMessage(messages: [result]),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(1));
        expect(assistants.single.message.content, const [
          TextContent(text: 'Completed live response'),
        ]);
        expect(streamingCubit.state.isStreaming, isFalse);
      },
    );

    test(
      'history replace keeps richer live content for the same assistant id',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        final completeAssistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: const [TextContent(text: 'Complete response')],
            model: 'codex',
          ),
        );
        final incompleteAssistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: const [TextContent(text: '')],
            model: 'codex',
          ),
        );

        mockBridge.emitMessage(completeAssistant, sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(
          HistoryMessage(messages: [incompleteAssistant]),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final assistant = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .single;
        expect(assistant.message.content, const [
          TextContent(text: 'Complete response'),
        ]);
      },
    );

    test(
      'history replace losslessly merges a shorter assistant with the same id',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const liveAssistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-owner',
            role: 'assistant',
            content: [TextContent(text: 'Complete response')],
            model: 'codex',
          ),
          artifacts: [
            ArtifactRef(
              id: 'artifact-live',
              filename: 'report.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 12,
              kind: 'preview',
              source: 'assistant_markdown',
              textContentIndex: 0,
            ),
          ],
          artifactContentIndexOffset: 2,
        );
        const historyAssistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'assistant-owner',
            role: 'assistant',
            content: [TextContent(text: 'Complete')],
            model: 'codex',
          ),
        );

        mockBridge.emitMessage(liveAssistant, sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(
          const HistoryMessage(messages: [historyAssistant]),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final assistant = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .single;
        expect(assistant.message.content, const [
          TextContent(text: 'Complete response'),
        ]);
        expect(assistant.artifacts.single.id, 'artifact-live');
        expect(assistant.artifactMessageId, 'assistant-owner');
        expect(assistant.artifactContentIndexOffset, 2);
      },
    );

    test(
      'history replace losslessly merges a tool result with the same id',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const liveResult = ToolResultMessage(
          toolUseId: 'tool-owner',
          content: 'Complete tool output',
          toolName: 'Read',
          images: [
            ImageRef(
              id: 'image-live',
              url: '/artifacts/image-live',
              mimeType: 'image/png',
            ),
          ],
          artifacts: [
            ArtifactRef(
              id: 'artifact-tool-live',
              filename: 'output.txt',
              mimeType: 'text/plain',
              sizeBytes: 20,
              kind: 'download',
              source: 'structured_tool',
            ),
          ],
        );
        const historyResult = ToolResultMessage(
          toolUseId: 'tool-owner',
          content: 'Complete',
        );

        mockBridge.emitMessage(liveResult, sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(
          const HistoryMessage(messages: [historyResult]),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final result = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<ToolResultMessage>()
            .single;
        expect(result.content, 'Complete tool output');
        expect(result.toolName, 'Read');
        expect(result.images.single.id, 'image-live');
        expect(result.artifacts.single.id, 'artifact-tool-live');
      },
    );

    test(
      'history replace deduplicates matching assistants with different ids',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        final liveAssistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'live-assistant-id',
            role: 'assistant',
            content: const [TextContent(text: 'Completed response')],
            model: 'codex',
          ),
        );
        final historyAssistant = AssistantServerMessage(
          messageUuid: 'history-item-id',
          message: AssistantMessage(
            id: 'history-assistant-id',
            role: 'assistant',
            content: const [TextContent(text: 'Completed response')],
            model: 'codex',
          ),
        );

        mockBridge.emitMessage(liveAssistant, sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(
          HistoryMessage(messages: [historyAssistant]),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(1));
        expect(assistants.single.message.id, 'history-assistant-id');
      },
    );

    test(
      'history replace consumes provisional aliases one for one and keeps artifacts',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        AssistantServerMessage provisional(String id, {bool artifact = false}) {
          return AssistantServerMessage(
            message: AssistantMessage(
              id: id,
              role: 'assistant',
              content: const [TextContent(text: 'Same response')],
              model: 'codex',
            ),
            artifacts: artifact
                ? const [
                    ArtifactRef(
                      id: 'artifact-provisional',
                      filename: 'result.pdf',
                      mimeType: 'application/pdf',
                      sizeBytes: 12,
                      kind: 'preview',
                      source: 'assistant_markdown',
                    ),
                  ]
                : const [],
          );
        }

        const canonical = AssistantServerMessage(
          messageUuid: 'canonical-item',
          message: AssistantMessage(
            id: 'canonical-item',
            role: 'assistant',
            content: [TextContent(text: 'Same response')],
            model: 'codex',
          ),
        );

        mockBridge.emitMessage(
          provisional('live-1', artifact: true),
          sessionId: 's1',
        );
        mockBridge.emitMessage(provisional('live-2'), sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(
          const HistoryMessage(messages: [canonical]),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(2));
        expect(
          assistants
              .expand((message) => message.artifacts)
              .map((ref) => ref.id),
          contains('artifact-provisional'),
        );
      },
    );

    test(
      'canonical aliases consume distinct provisional assistants one for one',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        AssistantServerMessage assistant(String id, {String? uuid}) {
          return AssistantServerMessage(
            messageUuid: uuid,
            message: AssistantMessage(
              id: id,
              role: 'assistant',
              content: const [TextContent(text: 'Same response')],
              model: 'codex',
            ),
          );
        }

        mockBridge.emitMessage(assistant('live-1'), sessionId: 's1');
        mockBridge.emitMessage(assistant('live-2'), sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(
          assistant('canonical-1', uuid: 'canonical-1'),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          assistant('canonical-2', uuid: 'canonical-2'),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(2));
        expect(assistants.map((message) => message.messageUuid), [
          'canonical-1',
          'canonical-2',
        ]);
      },
    );

    test(
      'history delta deduplicates current-turn messages with different ids',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        final liveAssistant = AssistantServerMessage(
          message: AssistantMessage(
            id: 'live-assistant-id',
            role: 'assistant',
            content: const [TextContent(text: 'Completed response')],
            model: 'codex',
          ),
        );
        final historyAssistant = AssistantServerMessage(
          messageUuid: 'history-item-id',
          message: AssistantMessage(
            id: 'history-assistant-id',
            role: 'assistant',
            content: const [TextContent(text: 'Completed response')],
            model: 'codex',
          ),
        );
        const liveResult = ResultMessage(
          subtype: 'success',
          result: 'Completed response',
          sessionId: 'live-thread-id',
        );
        const historyResult = ResultMessage(
          subtype: 'success',
          result: 'Completed response',
          sessionId: 'canonical-thread-id',
        );

        mockBridge.emitMessage(liveAssistant, sessionId: 's1');
        mockBridge.emitMessage(liveResult, sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(historyAssistant, sessionId: 's1');
        mockBridge.emitMessage(historyResult, sessionId: 's1');
        await pumpEventQueue();

        final serverMessages = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .toList();
        expect(
          serverMessages.whereType<AssistantServerMessage>(),
          hasLength(1),
        );
        expect(serverMessages.whereType<ResultMessage>(), hasLength(1));
      },
    );

    test('deduplicates repeated guardian approvals in the same turn', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      const approval = GuardianApprovalMessage(
        risk: GuardianApprovalRisk.medium,
        reason: 'Launching the app writes files outside the workspace.',
        authorization: 'medium',
      );

      mockBridge.emitMessage(approval, sessionId: 's1');
      mockBridge.emitMessage(approval, sessionId: 's1');
      await pumpEventQueue();

      final approvals = cubit.state.entries
          .whereType<ServerChatEntry>()
          .map((entry) => entry.message)
          .whereType<GuardianApprovalMessage>();
      expect(approvals, hasLength(1));
    });

    test(
      'same-turn live assistants with matching text remain distinct',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        AssistantServerMessage assistant(String id) => AssistantServerMessage(
          message: AssistantMessage(
            id: id,
            role: 'assistant',
            content: const [TextContent(text: 'Same response')],
            model: 'codex',
          ),
        );

        mockBridge.emitMessage(assistant('assistant-1'), sessionId: 's1');
        mockBridge.emitMessage(assistant('assistant-2'), sessionId: 's1');
        await pumpEventQueue();

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>();
        expect(assistants, hasLength(2));
      },
    );

    test(
      'stale history keeps same-text assistant from the current turn',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        AssistantServerMessage assistant(String id) => AssistantServerMessage(
          message: AssistantMessage(
            id: id,
            role: 'assistant',
            content: const [TextContent(text: 'OK')],
            model: 'codex',
          ),
        );
        const firstUser = UserInputMessage(
          text: 'Same prompt',
          userMessageUuid: 'user-turn-1',
        );
        const secondUser = UserInputMessage(
          text: 'Same prompt',
          userMessageUuid: 'user-turn-2',
        );
        final initialHistory = HistoryMessage(
          messages: [firstUser, assistant('assistant-1'), secondUser],
        );
        final staleHistory = HistoryMessage(
          messages: [firstUser, assistant('assistant-1')],
        );

        mockBridge.emitMessage(initialHistory, sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(assistant('assistant-2'), sessionId: 's1');
        await pumpEventQueue();
        mockBridge.emitMessage(staleHistory, sessionId: 's1');
        await pumpEventQueue();

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(2));
        expect(assistants.map((message) => message.message.id), [
          'assistant-1',
          'assistant-2',
        ]);
      },
    );

    test(
      'history UUID matches a local client-id user at the turn boundary',
      () async {
        final cubit = createCubit('s1', provider: Provider.claude);
        addTearDown(cubit.close);

        cubit.sendMessage('Same prompt');
        await pumpEventQueue();
        expect(cubit.state.entries.whereType<UserChatEntry>(), hasLength(1));

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              UserInputMessage(
                text: 'Same prompt',
                userMessageUuid: 'server-user-uuid',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Same prompt');
      },
    );

    test(
      'pending client id binds the latest matching canonical user occurrence',
      () async {
        final cubit = createCubit('s1', provider: Provider.claude);
        addTearDown(cubit.close);

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              UserInputMessage(
                text: 'Repeated prompt',
                userMessageUuid: 'server-user-1',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();
        cubit.sendMessage('Repeated prompt', clientMessageId: 'local-client-2');
        await pumpEventQueue();

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              UserInputMessage(
                text: 'Repeated prompt',
                userMessageUuid: 'server-user-1',
              ),
              UserInputMessage(
                text: 'Repeated prompt',
                userMessageUuid: 'server-user-2',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(2));
        expect(users.first.messageUuid, 'server-user-1');
        expect(users.first.clientMessageId, isNull);
        expect(users.last.messageUuid, 'server-user-2');
        expect(users.last.clientMessageId, 'local-client-2');
      },
    );

    test(
      'same-text UUID-less history keeps local image provenance by occurrence',
      () async {
        final cubit = createCubit('s1', provider: Provider.claude);
        addTearDown(cubit.close);
        final firstImage = Uint8List.fromList([1, 2, 3]);
        final secondImage = Uint8List.fromList([4, 5, 6]);

        cubit.sendMessage(
          'Same prompt',
          clientMessageId: 'local-first',
          images: [(bytes: firstImage, mimeType: 'image/png')],
        );
        cubit.sendMessage(
          'Same prompt',
          clientMessageId: 'local-second',
          images: [(bytes: secondImage, mimeType: 'image/png')],
        );
        expect(cubit.state.entries.whereType<UserChatEntry>(), hasLength(2));

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              UserInputMessage(text: 'Same prompt'),
              UserInputMessage(text: 'Same prompt'),
            ],
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(2));
        expect(users[0].imageBytesList.single, firstImage);
        expect(users[1].imageBytesList.single, secondImage);
      },
    );

    test(
      'identical assistant text in a later turn is not deduplicated',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        AssistantServerMessage assistant(String id) => AssistantServerMessage(
          message: AssistantMessage(
            id: id,
            role: 'assistant',
            content: const [TextContent(text: 'Same response')],
            model: 'codex',
          ),
        );

        mockBridge.emitMessage(assistant('assistant-1'), sessionId: 's1');
        mockBridge.emitMessage(
          const ResultMessage(subtype: 'success'),
          sessionId: 's1',
        );
        await pumpEventQueue();
        mockBridge.emitMessage(
          HistoryMessage(
            messages: [
              assistant('assistant-1'),
              const ResultMessage(subtype: 'success'),
            ],
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();
        mockBridge.emitMessage(
          const UserInputMessage(
            text: 'Ask again',
            userMessageUuid: 'user-turn-2',
          ),
          sessionId: 's1',
        );
        await pumpEventQueue();
        expect(cubit.state.entries.whereType<UserChatEntry>(), hasLength(1));
        mockBridge.emitMessage(assistant('assistant-2'), sessionId: 's1');
        await pumpEventQueue();

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>();
        expect(assistants, hasLength(2));
      },
    );

    test(
      'codex assistant response clears delivery pending without ack',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('Ack-less online Codex input');

        await Future<void>.delayed(const Duration(milliseconds: 650));
        expect(cubit.state.queuedInput, isNull);
        expect(
          cubit.state.entries.whereType<UserChatEntry>().single.status,
          MessageStatus.sending,
        );

        mockBridge.emitMessage(
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'a1',
              role: 'assistant',
              content: [const TextContent(text: 'delivered')],
              model: 'codex',
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.queuedInput, isNull);
        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Ack-less online Codex input');
        expect(users.single.status, MessageStatus.sent);
      },
    );

    test('codex delivery pending input never exposes queue controls', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      mockBridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      cubit.sendMessage('Dismiss delivery pending');
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(cubit.state.queuedInput, isNull);
      expect(
        cubit.state.entries.whereType<UserChatEntry>().single.status,
        MessageStatus.sending,
      );
      expect(mockBridge.sentMessages, hasLength(1));
    });

    test(
      'codex delivery pending input survives session cubit recreation',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('Recreate delivery pending');
        await cubit.close();

        await Future<void>.delayed(const Duration(milliseconds: 650));

        final restored = createCubit('s1', provider: Provider.codex);
        addTearDown(restored.close);
        await Future.microtask(() {});

        expect(restored.state.queuedInput, isNull);
        final restoredPendingUsers = restored.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(restoredPendingUsers, hasLength(1));
        expect(restoredPendingUsers.single.text, 'Recreate delivery pending');
        expect(restoredPendingUsers.single.status, MessageStatus.sending);

        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: payload['clientMessageId'] as String,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(restored.state.queuedInput, isNull);
        final users = restored.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Recreate delivery pending');
        expect(users.single.status, MessageStatus.sent);
      },
    );

    test(
      'all online pending inputs survive a session cubit recreation',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        cubit.sendMessage('Pending A');
        cubit.sendMessage('Pending B');
        final sent = mockBridge.sentMessages
            .map(
              (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
            )
            .toList(growable: false);
        await cubit.close();

        final restored = createCubit('s1', provider: Provider.codex);
        addTearDown(restored.close);
        await Future.microtask(() {});

        var users = restored.state.entries.whereType<UserChatEntry>().toList();
        expect(users.map((entry) => entry.text), ['Pending A', 'Pending B']);
        expect(
          users.map((entry) => entry.status),
          everyElement(MessageStatus.sending),
        );

        for (final payload in sent) {
          mockBridge.emitMessage(
            InputAckMessage(
              sessionId: 's1',
              clientMessageId: payload['clientMessageId'] as String,
            ),
            sessionId: 's1',
          );
        }
        await pumpEventQueue();

        users = restored.state.entries.whereType<UserChatEntry>().toList();
        expect(users.map((entry) => entry.text), ['Pending A', 'Pending B']);
        expect(
          users.map((entry) => entry.status),
          everyElement(MessageStatus.sent),
        );
      },
    );

    test(
      'one assistant response settles only one of several pending inputs',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        cubit.sendMessage('Pending A');
        cubit.sendMessage('Pending B');

        mockBridge.emitMessage(
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-a',
              role: 'assistant',
              content: const [TextContent(text: 'Answer A')],
              model: 'codex',
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users.map((entry) => entry.status), [
          MessageStatus.sent,
          MessageStatus.sending,
        ]);
        expect(
          mockBridge
              .deliveryPendingInputsForSession('s1')
              .map((item) => item.text),
          ['Pending B'],
        );
        await cubit.close();

        final restored = createCubit('s1', provider: Provider.codex);
        addTearDown(restored.close);
        await Future.microtask(() {});
        expect(
          restored.state.entries.whereType<UserChatEntry>().map(
            (entry) => entry.text,
          ),
          ['Pending B'],
        );
      },
    );

    test(
      'codex hidden delivery pending input survives fast recreation and ack',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.idle),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage('Recreate before delivery delay');
        final payload =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        await cubit.close();

        final restored = createCubit('s1', provider: Provider.codex);
        addTearDown(restored.close);
        await Future.microtask(() {});

        expect(restored.state.queuedInput, isNull);
        final restoredPendingUsers = restored.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(restoredPendingUsers, hasLength(1));
        expect(restoredPendingUsers.single.status, MessageStatus.sending);

        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: payload['clientMessageId'] as String,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        await Future<void>.delayed(const Duration(milliseconds: 650));

        expect(restored.state.queuedInput, isNull);
        final users = restored.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(users, hasLength(1));
        expect(users.single.text, 'Recreate before delivery delay');
        expect(users.single.status, MessageStatus.sent);
      },
    );

    test('input rejection clears restored delivery pending state', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      mockBridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      cubit.sendMessage('Reject restored delivery pending');
      final payload =
          jsonDecode(mockBridge.sentMessages.single.toJson())
              as Map<String, dynamic>;
      mockBridge.emitMessage(
        InputRejectedMessage(
          sessionId: 's1',
          clientMessageId: payload['clientMessageId'] as String,
          reason: 'rejected',
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      await cubit.close();

      final restored = createCubit('s1', provider: Provider.codex);
      addTearDown(restored.close);
      await Future.microtask(() {});

      expect(restored.state.queuedInput, isNull);
      expect(restored.state.entries.whereType<UserChatEntry>(), isEmpty);
    });

    test(
      'codex sendMessage includes structured skills and app mentions',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'supported_commands',
            provider: 'codex',
            skills: ['skill-creator'],
            skillMetadata: [
              CodexSkillMetadata(
                name: 'skill-creator',
                path: '/tmp/skill-creator/SKILL.md',
                description: 'Create a skill',
              ),
            ],
            apps: ['demo-app'],
            appMetadata: [
              CodexAppMetadata(
                id: 'demo-app',
                name: 'Demo App',
                description: 'Example connector',
              ),
            ],
            plugins: ['sample'],
            pluginMetadata: [
              CodexPluginMetadata(
                id: 'sample@test',
                name: 'sample',
                path: 'plugin://sample@test',
                marketplaceName: 'test',
                displayName: 'Sample Plugin',
                shortDescription: 'Example plugin',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.sendMessage(
          r'$skill-creator draft a skill and ask $demo-app with @sample',
        );

        expect(mockBridge.sentMessages, hasLength(1));
        final json =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(json['skills'], [
          {'name': 'skill-creator', 'path': '/tmp/skill-creator/SKILL.md'},
        ]);
        expect(json['mentions'], [
          {'name': 'Demo App', 'path': 'app://demo-app'},
          {'name': 'Sample Plugin', 'path': 'plugin://sample@test'},
        ]);
      },
    );

    test(
      'codex sendMessage includes structured file and directory mentions',
      () async {
        final cubit = createCubit(
          's1',
          provider: Provider.codex,
          initialProjectPath: '/tmp/project',
        );
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage(
          'Review @apps/mobile/ and @apps/mobile/lib/main.dart',
          mentionablePaths: const [
            'apps/',
            'apps/mobile/',
            'apps/mobile/lib/',
            'apps/mobile/lib/main.dart',
          ],
        );

        expect(mockBridge.sentMessages, hasLength(1));
        final json =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(json['mentions'], [
          {'name': 'apps/mobile/', 'path': '/tmp/project/apps/mobile/'},
          {
            'name': 'apps/mobile/lib/main.dart',
            'path': '/tmp/project/apps/mobile/lib/main.dart',
          },
        ]);
      },
    );

    test('codex sendMessage merges dropped file mentions once', () async {
      final cubit = createCubit(
        's1',
        provider: Provider.codex,
        initialProjectPath: '/tmp/project',
      );
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.sendMessage(
        'Review @notes.txt',
        mentionablePaths: const ['notes.txt'],
        additionalMentions: const [
          {'name': 'notes.txt', 'path': '/tmp/project/notes.txt'},
          {'name': 'report.pdf', 'path': '/Users/test/Downloads/report.pdf'},
        ],
      );

      final json =
          jsonDecode(mockBridge.sentMessages.single.toJson())
              as Map<String, dynamic>;
      expect(json['mentions'], [
        {'name': 'notes.txt', 'path': '/tmp/project/notes.txt'},
        {'name': 'report.pdf', 'path': '/Users/test/Downloads/report.pdf'},
      ]);
    });

    test('sendMessage preserves a caller-supplied delivery identity', () async {
      final cubit = createCubit('s1', provider: Provider.claude);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.sendMessage(
        'Deliver once',
        clientMessageId: 'persisted-submission-1',
      );

      final json =
          jsonDecode(mockBridge.sentMessages.single.toJson())
              as Map<String, dynamic>;
      expect(json['clientMessageId'], 'persisted-submission-1');
      expect(
        cubit.state.entries.whereType<UserChatEntry>().single.clientMessageId,
        'persisted-submission-1',
      );
    });

    test(
      'codex command-like text with a dropped file remains a message',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage(
          '/goal',
          additionalMentions: const [
            {'name': 'goal.md', 'path': '/Users/test/Downloads/goal.md'},
          ],
        );

        expect(mockBridge.sentMessages, hasLength(1));
        final json =
            jsonDecode(mockBridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(json['text'], '/goal');
        expect(json['mentions'], [
          {'name': 'goal.md', 'path': '/Users/test/Downloads/goal.md'},
        ]);
      },
    );

    test('approve clears approval state and sends message', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      const permMsg = PermissionRequestMessage(
        toolUseId: 'tool-1',
        toolName: 'bash',
        input: {'command': 'ls'},
      );
      mockBridge.emitMessage(permMsg, sessionId: 's1');
      await Future.microtask(() {});

      cubit.approve('tool-1');

      expect(cubit.state.approval, isA<ApprovalNone>());
      expect(mockBridge.sentMessages, hasLength(1));
    });

    test(
      'disconnected approval stays visible and is not marked responded',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        const permission = PermissionRequestMessage(
          toolUseId: 'tool-live-only',
          toolName: 'bash',
          input: {'command': 'ls'},
        );
        mockBridge.emitMessage(permission, sessionId: 's1');
        await Future.microtask(() {});
        mockBridge.connected = false;

        cubit.approve('tool-live-only');

        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(mockBridge.sentMessages, isEmpty);
        expect(
          mockBridge.respondedToolUseIds('s1'),
          isNot(contains('tool-live-only')),
        );
      },
    );

    test(
      'tool suggestion install keeps approval visible while pending',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        const permission = PermissionRequestMessage(
          toolUseId: 'approval-0',
          toolName: 'ToolSuggestion',
          input: {'toolName': 'GitHub', 'installState': 'idle'},
        );
        mockBridge.emitMessage(permission, sessionId: 's1');
        await Future.microtask(() {});

        cubit.installToolSuggestion('approval-0');

        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(mockBridge.sentMessages, hasLength(1));
        expect(jsonDecode(mockBridge.sentMessages.single.toJson()), {
          'type': 'install_tool_suggestion',
          'toolUseId': 'approval-0',
          'sessionId': 's1',
        });
      },
    );

    test('server resolution clears a completed tool suggestion', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const PermissionRequestMessage(
          toolUseId: 'approval-0',
          toolName: 'ToolSuggestion',
          input: {'toolName': 'GitHub', 'installState': 'installing'},
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      mockBridge.emitMessage(
        const PermissionResolvedMessage(toolUseId: 'approval-0'),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.approval, isA<ApprovalNone>());
    });

    test('approved permission is not restored by stale history', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});
      const permission = PermissionRequestMessage(
        toolUseId: 'tool-1',
        toolName: 'bash',
        input: {'command': 'ls'},
      );

      mockBridge.emitMessage(permission, sessionId: 's1');
      await Future.microtask(() {});
      cubit.approve('tool-1');
      mockBridge.emitMessage(
        const HistoryMessage(
          messages: [
            permission,
            StatusMessage(status: ProcessStatus.waitingApproval),
          ],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.approval, isA<ApprovalNone>());
    });

    test(
      'tool result does not allow stale approval history to replay',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});
        const permission = PermissionRequestMessage(
          toolUseId: 'tool-1',
          toolName: 'bash',
          input: {'command': 'ls'},
        );

        mockBridge.emitMessage(permission, sessionId: 's1');
        await Future.microtask(() {});
        cubit.reject('tool-1');
        mockBridge.emitMessage(
          const ToolResultMessage(toolUseId: 'tool-1', content: 'rejected'),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              permission,
              StatusMessage(status: ProcessStatus.waitingApproval),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.approval, isA<ApprovalNone>());
      },
    );

    test('answered question is not restored by stale history', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});
      final ask = AssistantServerMessage(
        message: AssistantMessage(
          id: 'ask-message',
          role: 'assistant',
          content: [
            const ToolUseContent(
              id: 'ask-1',
              name: 'AskUserQuestion',
              input: {
                'questions': [
                  {'question': 'Which option?'},
                ],
              },
            ),
          ],
          model: 'claude',
        ),
      );

      mockBridge.emitMessage(ask, sessionId: 's1');
      await Future.microtask(() {});
      cubit.answer('ask-1', 'A');
      mockBridge.emitMessage(
        HistoryMessage(
          messages: [
            ask,
            const StatusMessage(status: ProcessStatus.waitingApproval),
          ],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.approval, isA<ApprovalNone>());
    });

    test(
      'stale answered permission does not hide a later pending one',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});
        const answered = PermissionRequestMessage(
          toolUseId: 'tool-answered',
          toolName: 'bash',
          input: {'command': 'first'},
        );
        const pending = PermissionRequestMessage(
          toolUseId: 'tool-pending',
          toolName: 'bash',
          input: {'command': 'second'},
        );

        mockBridge.emitMessage(answered, sessionId: 's1');
        await Future.microtask(() {});
        cubit.approve('tool-answered');
        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              answered,
              pending,
              StatusMessage(status: ProcessStatus.waitingApproval),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(
          (cubit.state.approval as ApprovalPermission).toolUseId,
          'tool-pending',
        );
      },
    );

    test(
      'answered permission remains suppressed after cubit recreation',
      () async {
        final firstCubit = createCubit('s1');
        await Future.microtask(() {});
        const permission = PermissionRequestMessage(
          toolUseId: 'tool-answered',
          toolName: 'bash',
          input: {'command': 'ls'},
        );
        mockBridge.emitMessage(permission, sessionId: 's1');
        await Future.microtask(() {});
        firstCubit.approve('tool-answered');
        await firstCubit.close();

        final recreatedCubit = createCubit('s1');
        addTearDown(recreatedCubit.close);
        await Future.microtask(() {});
        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              permission,
              StatusMessage(status: ProcessStatus.waitingApproval),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(recreatedCubit.state.approval, isA<ApprovalNone>());
      },
    );

    test('approving ExitPlanMode also clears plan mode state', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const SystemMessage(
          subtype: 'set_permission_mode',
          provider: 'codex',
          permissionMode: 'plan',
          executionMode: 'default',
          planMode: true,
        ),
        sessionId: 's1',
      );
      mockBridge.emitMessage(
        const PermissionRequestMessage(
          toolUseId: 'tool-plan',
          toolName: 'ExitPlanMode',
          input: {'plan': 'Test plan'},
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      await Future.microtask(() {});

      expect(cubit.state.planMode, isTrue);
      expect(cubit.state.approval, isA<ApprovalPermission>());
      cubit.approve('tool-plan');

      expect(cubit.state.planMode, isFalse);
      expect(cubit.state.inPlanMode, isFalse);
      expect(cubit.state.permissionMode, PermissionMode.acceptEdits);
    });

    test('approving ExitPlanMode clears inPlanMode immediately', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        AssistantServerMessage(
          message: AssistantMessage(
            id: 'plan-msg',
            role: 'assistant',
            content: [
              const TextContent(text: 'Plan ready'),
              const ToolUseContent(
                id: 'tool-exit-1',
                name: 'EnterPlanMode',
                input: {},
              ),
            ],
            model: 'claude',
          ),
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      mockBridge.emitMessage(
        const PermissionRequestMessage(
          toolUseId: 'tool-exit-1',
          toolName: 'ExitPlanMode',
          input: {'plan': 'Implementation Plan'},
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.inPlanMode, isTrue);
      expect(cubit.state.approval, isA<ApprovalPermission>());

      cubit.approve('tool-exit-1');

      expect(cubit.state.approval, isA<ApprovalNone>());
      expect(cubit.state.inPlanMode, isFalse);
    });

    test('reject clears approval and plan mode', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      const permMsg = PermissionRequestMessage(
        toolUseId: 'tool-1',
        toolName: 'EnterPlanMode',
        input: {},
      );
      mockBridge.emitMessage(permMsg, sessionId: 's1');
      await Future.microtask(() {});

      cubit.reject('tool-1', message: 'No thanks');

      expect(cubit.state.approval, isA<ApprovalNone>());
      expect(cubit.state.inPlanMode, false);
    });

    test('setPermissionMode updates local mode state immediately', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.setPermissionMode(PermissionMode.plan);
      expect(cubit.state.permissionMode, PermissionMode.plan);
      expect(cubit.state.inPlanMode, isTrue);

      cubit.setPermissionMode(PermissionMode.defaultMode);
      expect(cubit.state.permissionMode, PermissionMode.defaultMode);
      expect(cubit.state.inPlanMode, isFalse);
    });

    test('setCodexModel updates state and sends bridge message', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      cubit.setCodexModel(
        ' gpt-5.4-mini ',
        reasoningEffort: ReasoningEffort.low,
      );

      expect(cubit.state.codexModel, 'gpt-5.4-mini');
      expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.low);
      expect(mockBridge.sentMessages, hasLength(1));
      expect(jsonDecode(mockBridge.sentMessages.single.toJson()), {
        'type': 'set_codex_model',
        'model': 'gpt-5.4-mini',
        'modelReasoningEffort': 'low',
        'sessionId': 's1',
      });
    });

    test('setCodexModel is ignored for non-Codex sessions', () async {
      final cubit = createCubit('s1', provider: Provider.claude);
      addTearDown(cubit.close);

      cubit.setCodexModel('gpt-5.4-mini', reasoningEffort: ReasoningEffort.low);

      expect(cubit.state.codexModel, isNull);
      expect(cubit.state.codexModelReasoningEffort, isNull);
      expect(mockBridge.sentMessages, isEmpty);
    });

    test('setCodexModel ignores an unchanged model and effort', () async {
      mockBridge.sessionSnapshot = const [
        SessionInfo(
          id: 's1',
          provider: 'codex',
          projectPath: '/project',
          status: 'idle',
          createdAt: '',
          lastActivityAt: '',
          codexModel: 'gpt-5.6-sol',
          codexModelReasoningEffort: 'ultra',
        ),
      ];
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      cubit.setCodexModel(
        'gpt-5.6-sol',
        reasoningEffort: ReasoningEffort.ultra,
      );

      expect(mockBridge.sentMessages, isEmpty);
      expect(mockBridge.restoredCodexModels, isEmpty);
    });

    test('setCodexSpeed updates state and sends bridge message', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      cubit.setCodexSpeed(CodexSpeed.fast);

      expect(cubit.state.codexSpeed, CodexSpeed.fast);
      expect(jsonDecode(mockBridge.sentMessages.single.toJson()), {
        'type': 'set_codex_speed',
        'serviceTier': 'fast',
        'sessionId': 's1',
      });
    });

    test(
      'external owner rejection rolls model and speed back to provider facts',
      () async {
        mockBridge.sessionSnapshot = const [
          SessionInfo(
            id: 's1',
            provider: 'codex',
            projectPath: '/project',
            status: 'idle',
            createdAt: '',
            lastActivityAt: '',
            codexModel: 'gpt-5.6-sol',
            codexModelReasoningEffort: 'ultra',
            codexServiceTier: 'fast',
          ),
        ];
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);

        cubit.setCodexModel(
          'gpt-5.4-mini',
          reasoningEffort: ReasoningEffort.high,
        );
        cubit.setCodexSpeed(CodexSpeed.standard);
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.high);
        expect(cubit.state.codexSpeed, CodexSpeed.standard);

        mockBridge.emitMessage(
          const ErrorMessage(
            sessionId: 's1',
            message: 'Codex Desktop owns the active turn.',
            errorCode: 'codex_settings_owned_elsewhere',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.codexModel, 'gpt-5.6-sol');
        expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
        expect(cubit.state.codexSpeed, CodexSpeed.fast);
        expect(cubit.codexServiceTierRaw.value, 'fast');
        expect(mockBridge.restoredCodexModels.single, {
          'sessionId': 's1',
          'model': 'gpt-5.6-sol',
          'modelReasoningEffort': 'ultra',
        });
        expect(mockBridge.restoredCodexSpeeds.single, {
          'sessionId': 's1',
          'serviceTier': 'fast',
        });
      },
    );

    test('permission mode rolls back on mode-change error', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.setPermissionMode(PermissionMode.bypassPermissions);
      expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);

      mockBridge.emitMessage(
        const ErrorMessage(
          message: 'Failed to set permission mode: forced test failure',
          errorCode: 'set_permission_mode_rejected',
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.permissionMode, PermissionMode.defaultMode);
      expect(cubit.state.inPlanMode, isFalse);
    });

    test('next-turn codex permissions roll back all optimistic fields', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      expect(cubit.state.codexPermissionStateKnown, isFalse);
      cubit.setCodexPermissionsMode(
        CodexPermissionsMode.fullAccess,
        applyStrategy: CodexPermissionApplyStrategy.nextTurn,
      );
      final permissionChangeId =
          (jsonDecode(mockBridge.sentMessages.last.toJson())
                  as Map<String, dynamic>)['permissionChangeId']
              as String;
      expect(cubit.state.codexPermissionStateKnown, isTrue);
      expect(cubit.state.codexPermissionsMode, CodexPermissionsMode.fullAccess);
      expect(cubit.state.sandboxMode, SandboxMode.off);

      mockBridge.emitMessage(
        ErrorMessage(
          message:
              'This Codex backend does not support next-turn permission updates.',
          errorCode: 'set_permission_mode_rejected',
          permissionChangeId: permissionChangeId,
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(
        cubit.state.codexPermissionsMode,
        CodexPermissionsMode.defaultPermissions,
      );
      expect(cubit.state.codexPermissionStateKnown, isFalse);
      expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
      expect(cubit.state.codexApprovalsReviewer, 'user');
      expect(cubit.state.sandboxMode, SandboxMode.on);
    });

    test(
      'permission update acknowledgement clears stale rollback state',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.setCodexPermissionsMode(
          CodexPermissionsMode.autoReview,
          applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        );
        final permissionChangeId =
            (jsonDecode(mockBridge.sentMessages.last.toJson())
                    as Map<String, dynamic>)['permissionChangeId']
                as String;
        mockBridge.emitMessage(
          SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            approvalPolicy: 'on-request',
            approvalsReviewer: 'auto_review',
            codexPermissionsMode: 'autoReview',
            sandboxMode: 'workspace-write',
            planMode: false,
            permissionChangeId: permissionChangeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.codexPermissionStateKnown, isTrue);
        mockBridge.emitMessage(
          ErrorMessage(
            message: 'late duplicate failure',
            errorCode: 'set_permission_mode_rejected',
            permissionChangeId: permissionChangeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.autoReview,
        );
        expect(cubit.state.codexApprovalsReviewer, 'auto_review');
      },
    );

    test(
      'restart-now hides the old approval and fully rolls back when offline',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});
        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.running),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const PermissionRequestMessage(
            toolUseId: 'old-approval',
            toolName: 'Bash',
            input: {'command': 'pwd'},
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        await Future.microtask(() {});
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.approval, isA<ApprovalPermission>());

        mockBridge.connected = false;
        cubit.setCodexPermissionsMode(
          CodexPermissionsMode.fullAccess,
          applyStrategy: CodexPermissionApplyStrategy.restartNow,
        );
        await Future.microtask(() {});

        expect(mockBridge.sentMessages, isEmpty);
        expect(cubit.state.status, ProcessStatus.running);
        expect(cubit.state.approval, isA<ApprovalPermission>());
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.defaultPermissions,
        );
        expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
        expect(cubit.state.codexApprovalsReviewer, 'user');
        expect(cubit.state.sandboxMode, SandboxMode.on);
      },
    );

    test(
      'mismatched permission operation errors cannot roll back a newer state',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.setCodexPermissionsMode(
          CodexPermissionsMode.autoReview,
          applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        );
        final permissionChangeId =
            (jsonDecode(mockBridge.sentMessages.last.toJson())
                    as Map<String, dynamic>)['permissionChangeId']
                as String;
        mockBridge.emitMessage(
          const ErrorMessage(
            message: 'failure from another permission operation',
            errorCode: 'set_permission_mode_rejected',
            permissionChangeId: 'different-operation',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.autoReview,
        );

        mockBridge.emitMessage(
          ErrorMessage(
            message: 'matching failure',
            errorCode: 'set_permission_mode_rejected',
            permissionChangeId: permissionChangeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.defaultPermissions,
        );
      },
    );

    test(
      'late permission acknowledgement becomes the newer rollback base',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.setCodexPermissionsMode(
          CodexPermissionsMode.autoReview,
          applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        );
        final oldChangeId =
            (jsonDecode(mockBridge.sentMessages.last.toJson())
                    as Map<String, dynamic>)['permissionChangeId']
                as String;
        mockBridge.emitMessage(
          ErrorMessage(
            message: 'first operation timed out',
            errorCode: 'set_permission_mode_rejected',
            permissionChangeId: oldChangeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        cubit.setCodexPermissionsMode(
          CodexPermissionsMode.fullAccess,
          applyStrategy: CodexPermissionApplyStrategy.nextTurn,
        );
        final newChangeId =
            (jsonDecode(mockBridge.sentMessages.last.toJson())
                    as Map<String, dynamic>)['permissionChangeId']
                as String;
        mockBridge.emitMessage(
          SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'acceptEdits',
            executionMode: 'default',
            approvalPolicy: 'on-request',
            approvalsReviewer: 'auto_review',
            codexPermissionsMode: 'autoReview',
            sandboxMode: 'workspace-write',
            planMode: false,
            permissionChangeId: oldChangeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.isPermissionChangePending, isTrue);
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.fullAccess,
        );
        expect(cubit.state.sandboxMode, SandboxMode.off);

        mockBridge.emitMessage(
          ErrorMessage(
            message: 'newer operation failed',
            errorCode: 'set_permission_mode_rejected',
            permissionChangeId: newChangeId,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.isPermissionChangePending, isFalse);
        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.autoReview,
        );
        expect(cubit.state.codexApprovalPolicy, CodexApprovalPolicy.onRequest);
        expect(cubit.state.codexApprovalsReviewer, 'auto_review');
        expect(cubit.state.sandboxMode, SandboxMode.on);
      },
    );

    test(
      'cross-client permission broadcasts update the sandbox state',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const SystemMessage(
            subtype: 'set_permission_mode',
            provider: 'codex',
            permissionMode: 'bypassPermissions',
            executionMode: 'fullAccess',
            approvalPolicy: 'never',
            approvalsReviewer: 'user',
            codexPermissionsMode: 'fullAccess',
            sandboxMode: 'danger-full-access',
            planMode: false,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(
          cubit.state.codexPermissionsMode,
          CodexPermissionsMode.fullAccess,
        );
        expect(cubit.state.sandboxMode, SandboxMode.off);
      },
    );

    test(
      'auto mode unavailable rolls back to previous permission mode',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.setPermissionMode(PermissionMode.auto);
        expect(cubit.state.permissionMode, PermissionMode.auto);

        mockBridge.emitMessage(
          const ErrorMessage(
            message:
                'Auto mode is unavailable in this environment. Keeping the current permission mode.',
            errorCode: 'auto_mode_unavailable',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.permissionMode, PermissionMode.defaultMode);
        expect(cubit.state.inPlanMode, isFalse);
      },
    );

    test('sandbox mode rolls back on mode-change error', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.setSandboxMode(SandboxMode.on);
      expect(cubit.state.sandboxMode, SandboxMode.on);

      mockBridge.emitMessage(
        const ErrorMessage(
          message: 'Failed to set sandbox mode: forced test failure',
          errorCode: 'set_sandbox_mode_rejected',
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.sandboxMode, SandboxMode.off);
    });

    test('history message adds entries', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      final historyMsg = HistoryMessage(
        messages: [
          const StatusMessage(status: ProcessStatus.idle),
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'a1',
              role: 'assistant',
              content: [TextContent(text: 'Hello!')],
              model: 'claude',
            ),
          ),
        ],
      );
      mockBridge.emitMessage(historyMsg, sessionId: 's1');
      await Future.microtask(() {});

      expect(cubit.state.entries, hasLength(1));
      expect(cubit.state.status, ProcessStatus.idle);
    });

    test(
      'canonical history enriches a cached assistant with artifacts',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const AssistantServerMessage(
            messageUuid: 'uuid-a1',
            message: AssistantMessage(
              id: 'a1',
              role: 'assistant',
              content: [TextContent(text: 'Report ready')],
              model: 'codex',
            ),
          ),
          sessionId: 's1',
        );
        await Future<void>.delayed(Duration.zero);

        mockBridge.emitMessage(
          const HistoryMessage(
            messages: [
              AssistantServerMessage(
                messageUuid: 'uuid-a1',
                message: AssistantMessage(
                  id: 'a1',
                  role: 'assistant',
                  content: [TextContent(text: 'Report ready')],
                  model: 'codex',
                ),
                artifacts: [
                  ArtifactRef(
                    id: 'artifact-1',
                    filename: 'report.pdf',
                    mimeType: 'application/pdf',
                    sizeBytes: 10,
                    kind: 'preview',
                    source: 'assistant_markdown',
                  ),
                ],
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(1));
        expect(assistants.single.artifacts.single.id, 'artifact-1');
      },
    );

    test(
      'enriched duplicate assistant merges artifacts without duplication',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const baseMessage = AssistantMessage(
          id: 'a-merge',
          role: 'assistant',
          content: [TextContent(text: 'Bundle ready')],
          model: 'codex',
        );
        mockBridge.emitMessage(
          const AssistantServerMessage(message: baseMessage),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const AssistantServerMessage(
            messageUuid: 'uuid-a-merge',
            message: baseMessage,
            artifacts: [
              ArtifactRef(
                id: 'artifact-merge',
                filename: 'bundle.zip',
                mimeType: 'application/zip',
                sizeBytes: 20,
                kind: 'preview',
                source: 'structured_tool',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future<void>.delayed(Duration.zero);

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(1));
        expect(assistants.single.messageUuid, 'uuid-a-merge');
        expect(assistants.single.artifacts.single.id, 'artifact-merge');
      },
    );

    test(
      'replacement id supersedes the same Markdown artifact candidate',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const message = AssistantMessage(
          id: 'owner-stable',
          role: 'assistant',
          content: [TextContent(text: '[Report](docs/report.pdf)')],
          model: 'codex',
        );
        const oldArtifact = ArtifactRef(
          id: 'artifact-before-registry-recovery',
          filename: 'report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 20,
          kind: 'preview',
          source: 'assistant_markdown',
          originalHref: 'docs/report.pdf',
          textContentIndex: 0,
        );
        const replacementArtifact = ArtifactRef(
          id: 'artifact-after-registry-recovery',
          filename: 'report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 20,
          kind: 'preview',
          source: 'assistant_markdown',
          originalHref: 'docs/report.pdf',
          textContentIndex: 0,
        );

        mockBridge.emitMessage(
          const AssistantServerMessage(
            message: message,
            artifacts: [oldArtifact],
          ),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const AssistantServerMessage(
            message: message,
            artifacts: [replacementArtifact],
          ),
          sessionId: 's1',
        );
        await Future<void>.delayed(Duration.zero);

        final assistant = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .single;
        expect(assistant.artifacts.map((artifact) => artifact.id), [
          'artifact-after-registry-recovery',
        ]);
      },
    );

    test(
      'a re-registered ref with a flipped kind supersedes the stale chip',
      () async {
        // Cross-version scenario: a pre-upgrade Bridge registered a project
        // .html ref as kind:"source" with projectRelativePath; after registry
        // eviction a post-upgrade Bridge re-registers the same candidate as
        // kind:"preview" without projectRelativePath. The chip must be
        // replaced in place, not duplicated (the stale id is dead anyway).
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        const message = AssistantMessage(
          id: 'owner-stable-kind-flip',
          role: 'assistant',
          content: [TextContent(text: '[Report](report.html)')],
          model: 'codex',
        );
        const oldArtifact = ArtifactRef(
          id: 'artifact-old-source-kind',
          filename: 'report.html',
          mimeType: 'text/html',
          sizeBytes: 20,
          kind: 'source',
          source: 'assistant_markdown',
          originalHref: 'report.html',
          textContentIndex: 0,
          projectRelativePath: 'report.html',
        );
        const replacementArtifact = ArtifactRef(
          id: 'artifact-new-preview-kind',
          filename: 'report.html',
          mimeType: 'text/html',
          sizeBytes: 20,
          kind: 'preview',
          source: 'assistant_markdown',
          originalHref: 'report.html',
          textContentIndex: 0,
        );

        mockBridge.emitMessage(
          const AssistantServerMessage(
            message: message,
            artifacts: [oldArtifact],
          ),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const AssistantServerMessage(
            message: message,
            artifacts: [replacementArtifact],
          ),
          sessionId: 's1',
        );
        await Future<void>.delayed(Duration.zero);

        final assistant = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .single;
        expect(assistant.artifacts.map((artifact) => artifact.id), [
          'artifact-new-preview-kind',
        ]);
      },
    );

    test(
      'same UUID with different message ids keeps only the selected owner refs',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        mockBridge.emitMessage(
          const AssistantServerMessage(
            messageUuid: 'shared-uuid',
            message: AssistantMessage(
              id: 'owner-old',
              role: 'assistant',
              content: [TextContent(text: 'Old response')],
              model: 'codex',
            ),
            artifacts: [
              ArtifactRef(
                id: 'artifact-old',
                filename: 'old.pdf',
                mimeType: 'application/pdf',
                sizeBytes: 10,
                kind: 'preview',
                source: 'assistant_markdown',
              ),
            ],
          ),
          sessionId: 's1',
        );
        mockBridge.emitMessage(
          const AssistantServerMessage(
            messageUuid: 'shared-uuid',
            message: AssistantMessage(
              id: 'owner-new',
              role: 'assistant',
              content: [TextContent(text: 'New response with artifact')],
              model: 'codex',
            ),
            artifacts: [
              ArtifactRef(
                id: 'artifact-new',
                filename: 'new.pdf',
                mimeType: 'application/pdf',
                sizeBytes: 20,
                kind: 'preview',
                source: 'assistant_markdown',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future<void>.delayed(Duration.zero);

        final assistants = cubit.state.entries
            .whereType<ServerChatEntry>()
            .map((entry) => entry.message)
            .whereType<AssistantServerMessage>()
            .toList();
        expect(assistants, hasLength(1));
        expect(assistants.single.artifactMessageId, 'owner-new');
        expect(assistants.single.artifacts.map((artifact) => artifact.id), [
          'artifact-new',
        ]);
      },
    );

    test('restores cached runtime messages before requesting history', () {
      mockBridge.cachedMessagesBySession['s1'] = [
        const StatusMessage(status: ProcessStatus.running),
        AssistantServerMessage(
          message: AssistantMessage(
            id: 'cached-a1',
            role: 'assistant',
            content: [const TextContent(text: 'Cached response')],
            model: 'claude',
          ),
        ),
      ];

      final cubit = createCubit('s1');
      addTearDown(cubit.close);

      expect(mockBridge.requestSessionHistoryCallCount, 1);
      expect(cubit.state.status, ProcessStatus.running);
      expect(cubit.state.entries, hasLength(1));
      final entry = cubit.state.entries.single as ServerChatEntry;
      final msg = entry.message as AssistantServerMessage;
      expect(
        (msg.message.content.single as TextContent).text,
        'Cached response',
      );
    });

    test('restores cached queue state without visible ack entries', () {
      mockBridge.cachedMessagesBySession['s1'] = [
        const InputAckMessage(sessionId: 's1', queued: true),
        const ConversationQueueMessage(
          sessionId: 's1',
          limit: 1,
          items: [
            QueuedInputItem(
              itemId: 'queued-1',
              text: 'Queued while busy',
              createdAt: '2026-04-28T00:00:00.000Z',
            ),
          ],
        ),
      ];

      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);

      expect(cubit.state.entries, isEmpty);
      expect(cubit.state.queuedInput?.itemId, 'queued-1');
      expect(cubit.state.queuedInput?.text, 'Queued while busy');
    });

    test('result message adds cost', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      const resultMsg = ResultMessage(
        subtype: 'completed',
        cost: 0.05,
        duration: 2.5,
        sessionId: 'claude-session-1',
      );
      mockBridge.emitMessage(resultMsg, sessionId: 's1');
      await Future.microtask(() {});

      expect(cubit.state.totalCost, 0.05);
    });

    test('retryMessage changes status to sending and resends', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.sendMessage('Test message');
      expect(cubit.state.entries, hasLength(1));

      cubit.sendMessage('Retry me');
      final entryToRetry = cubit.state.entries.last as UserChatEntry;

      mockBridge.sentMessages.clear();
      cubit.retryMessage(entryToRetry);

      final retriedEntry = cubit.state.entries.last as UserChatEntry;
      expect(retriedEntry.status, MessageStatus.sending);
      expect(retriedEntry.text, 'Retry me');
      expect(mockBridge.sentMessages, hasLength(1));
    });

    test('build calls requestSessionHistory for the session', () {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);

      expect(mockBridge.requestSessionHistoryCallCount, 1);
      expect(mockBridge.lastRequestedSessionId, 's1');
    });

    test(
      'statusRefreshTimer stops when status changes from starting',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.starting);

        mockBridge.emitMessage(
          const StatusMessage(status: ProcessStatus.running),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.status, ProcessStatus.running);
      },
    );

    testWidgets('starting history refresh has a bounded retry budget', (
      tester,
    ) async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);

      expect(mockBridge.requestSessionHistoryCallCount, 1);
      await tester.pump(const Duration(minutes: 5));

      expect(cubit.state.status, ProcessStatus.starting);
      expect(mockBridge.requestSessionHistoryCallCount, 5);
    });

    testWidgets(
      'starting history refresh pauses offline and restarts after reconnect',
      (tester) async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);

        mockBridge.emitConnection(BridgeConnectionState.disconnected);
        await tester.pump();
        await tester.pump(const Duration(minutes: 5));
        expect(mockBridge.requestSessionHistoryCallCount, 1);

        mockBridge.emitConnection(BridgeConnectionState.connected);
        await tester.pump();
        expect(mockBridge.requestSessionHistoryCallCount, 2);

        await tester.pump(const Duration(minutes: 5));
        expect(mockBridge.requestSessionHistoryCallCount, 6);
      },
    );

    test(
      'session-not-found stops history refresh and marks session unavailable',
      () async {
        final cubit = createCubit('missing-session');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(mockBridge.requestSessionHistoryCallCount, 1);
        mockBridge.emitMessage(
          const ErrorMessage(
            message: 'Session missing-session not found',
            errorCode: 'session_not_found',
            sessionId: 'missing-session',
          ),
          sessionId: 'missing-session',
        );
        await Future<void>.delayed(const Duration(milliseconds: 3100));

        expect(cubit.state.sessionUnavailable, isTrue);
        expect(mockBridge.requestSessionHistoryCallCount, 1);
      },
    );

    test(
      'ignores session-not-found errors scoped to another session',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        mockBridge.emitMessage(
          const ErrorMessage(
            message: 'Session s2 not found',
            errorCode: 'session_not_found',
            sessionId: 's2',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.sessionUnavailable, isFalse);
      },
    );

    test('ignores unscoped structured session-not-found errors', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const ErrorMessage(
          message: 'Session s1 not found',
          errorCode: 'session_not_found',
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.sessionUnavailable, isFalse);
    });

    test('ignores duplicate past history messages in same session', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      final pastHistory = PastHistoryMessage(
        claudeSessionId: 'old',
        messages: [
          PastMessage(
            role: 'user',
            content: [TextContent(text: 'Hi')],
          ),
        ],
      );

      mockBridge.emitMessage(pastHistory, sessionId: 's1');
      mockBridge.emitMessage(pastHistory, sessionId: 's1');
      await Future.microtask(() {});

      expect(cubit.state.entries, hasLength(1));
      expect(cubit.state.entries.first, isA<UserChatEntry>());
    });

    test(
      'queued messages are promoted to sent one-by-one when assistant responses arrive',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Message A');
        cubit.sendMessage('Message B');

        mockBridge.emitMessage(
          const InputAckMessage(sessionId: 's1', queued: true),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitMessage(
          const InputAckMessage(sessionId: 's1', queued: true),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        var users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users.map((e) => e.status).toList(), [
          MessageStatus.queued,
          MessageStatus.queued,
        ]);

        mockBridge.emitMessage(
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'a1',
              role: 'assistant',
              content: [TextContent(text: 'reply for A')],
              model: 'claude',
            ),
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        users = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(users.map((e) => e.status).toList(), [
          MessageStatus.sent,
          MessageStatus.queued,
        ]);
      },
    );

    test('input_ack(sent) advances sending messages one-by-one', () async {
      final cubit = createCubit('s1');
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.sendMessage('Message A');
      cubit.sendMessage('Message B');

      mockBridge.emitMessage(
        const InputAckMessage(sessionId: 's1', queued: false),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      var users = cubit.state.entries.whereType<UserChatEntry>().toList();
      expect(users.map((e) => e.status).toList(), [
        MessageStatus.sent,
        MessageStatus.sending,
      ]);

      mockBridge.emitMessage(
        const InputAckMessage(sessionId: 's1', queued: false),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      users = cubit.state.entries.whereType<UserChatEntry>().toList();
      expect(users.map((e) => e.status).toList(), [
        MessageStatus.sent,
        MessageStatus.sent,
      ]);
    });

    test(
      'input_ack with clientMessageId updates the matching message',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Message A');
        cubit.sendMessage('Message B');
        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        final secondClientMessageId = users[1].clientMessageId;

        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: secondClientMessageId,
            queued: false,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final updated = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(updated.map((e) => e.status).toList(), [
          MessageStatus.sending,
          MessageStatus.sent,
        ]);
      },
    );

    test(
      'ordinary staged input remains one check after provider acceptance',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Staged message');
        final user = cubit.state.entries.whereType<UserChatEntry>().single;
        final clientMessageId = user.clientMessageId!;

        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: clientMessageId,
            queued: false,
            stage: InputAckStage.bridgeAccepted,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(
          cubit.state.entries.whereType<UserChatEntry>().single.status,
          MessageStatus.bridgeAccepted,
        );

        mockBridge.emitMessage(
          InputDeliveryStatusMessage(
            sessionId: 's1',
            clientMessageId: clientMessageId,
            stage: InputDeliveryStage.providerAccepted,
            provider: 'codex',
            method: 'turn/start',
            occurredAt: '2026-07-31T00:00:00.000Z',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(
          cubit.state.entries.whereType<UserChatEntry>().single.status,
          MessageStatus.bridgeAccepted,
        );

        // A duplicate first-stage ack after reconnect keeps the same single
        // receipt; two-stage checks belong only to the next-turn queue panel.
        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: clientMessageId,
            queued: false,
            stage: InputAckStage.bridgeAccepted,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        expect(
          cubit.state.entries.whereType<UserChatEntry>().single.status,
          MessageStatus.bridgeAccepted,
        );
      },
    );

    test(
      'provider rejection preserves Bridge acceptance and remains retryable',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Rejected after queue');
        final clientMessageId = cubit.state.entries
            .whereType<UserChatEntry>()
            .single
            .clientMessageId!;
        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: clientMessageId,
            stage: InputAckStage.bridgeAccepted,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});
        mockBridge.emitMessage(
          InputDeliveryStatusMessage(
            sessionId: 's1',
            clientMessageId: clientMessageId,
            stage: InputDeliveryStage.providerRejected,
            provider: 'codex',
            method: 'turn/start',
            occurredAt: '2026-07-31T00:00:00.000Z',
            error: 'writer unavailable',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final status = cubit.state.entries
            .whereType<UserChatEntry>()
            .single
            .status;
        expect(status, MessageStatus.providerRejected);
        expect(status.canRetry, isTrue);
      },
    );

    test(
      'input_rejected with clientMessageId fails only the matching message',
      () async {
        final cubit = createCubit('s1');
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Message A');
        cubit.sendMessage('Message B');
        final users = cubit.state.entries.whereType<UserChatEntry>().toList();
        final firstClientMessageId = users[0].clientMessageId;

        mockBridge.emitMessage(
          InputRejectedMessage(
            sessionId: 's1',
            clientMessageId: firstClientMessageId,
            reason: 'conflict',
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        final updated = cubit.state.entries.whereType<UserChatEntry>().toList();
        expect(updated.map((e) => e.status).toList(), [
          MessageStatus.failed,
          MessageStatus.sending,
        ]);
      },
    );

    test('codex busy send waits for bridge queue state', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      mockBridge.emitMessage(
        const StatusMessage(status: ProcessStatus.running),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      cubit.sendMessage('Follow up');

      final optimistic = cubit.state.entries
          .whereType<UserChatEntry>()
          .toList();
      expect(optimistic, hasLength(1));
      expect(optimistic.single.status, MessageStatus.sending);
      expect(mockBridge.sentMessages.last.type, 'input');
      final inputPayload =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      final clientMessageId = inputPayload['clientMessageId'] as String;

      mockBridge.emitMessage(
        ConversationQueueMessage(
          sessionId: 's1',
          limit: 1,
          items: [
            QueuedInputItem(
              itemId: 'q1',
              text: 'Follow up',
              createdAt: '2026-04-25T00:00:00.000Z',
              clientMessageId: clientMessageId,
            ),
          ],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.entries.whereType<UserChatEntry>(), isEmpty);
      expect(cubit.state.queuedInput?.itemId, 'q1');
      expect(cubit.state.queuedInput?.text, 'Follow up');
      expect(
        cubit.state.queuedInput?.deliveryStage,
        QueuedInputDeliveryStage.bridgeAccepted,
      );

      mockBridge.emitMessage(
        InputAckMessage(
          sessionId: 's1',
          clientMessageId: clientMessageId,
          queued: true,
          stage: InputAckStage.bridgeAccepted,
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(
        cubit.state.queuedInput?.deliveryStage,
        QueuedInputDeliveryStage.bridgeAccepted,
      );

      mockBridge.emitMessage(
        InputDeliveryStatusMessage(
          sessionId: 's1',
          clientMessageId: clientMessageId,
          stage: InputDeliveryStage.providerAccepted,
          provider: 'codex',
          method: 'turn/start',
          occurredAt: '2026-07-31T00:00:00.000Z',
          queued: true,
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(
        cubit.state.queuedInput?.deliveryStage,
        QueuedInputDeliveryStage.providerAccepted,
      );

      // A stage-less legacy/reconnect queue snapshot cannot erase the
      // terminal provider fact already observed for the same client input.
      mockBridge.emitMessage(
        ConversationQueueMessage(
          sessionId: 's1',
          limit: 1,
          items: [
            QueuedInputItem(
              itemId: 'q1',
              text: 'Follow up',
              createdAt: '2026-04-25T00:00:00.000Z',
              clientMessageId: clientMessageId,
            ),
          ],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});
      expect(
        cubit.state.queuedInput?.deliveryStage,
        QueuedInputDeliveryStage.providerAccepted,
      );
    });

    test(
      'queued ack before a legacy queue snapshot migrates the matching bubble',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Legacy queued follow up');
        final clientMessageId = cubit.state.entries
            .whereType<UserChatEntry>()
            .single
            .clientMessageId!;

        mockBridge.emitMessage(
          InputAckMessage(
            sessionId: 's1',
            clientMessageId: clientMessageId,
            queued: true,
            stage: InputAckStage.bridgeAccepted,
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.queuedInput, isNull);
        expect(
          cubit.state.entries.whereType<UserChatEntry>().single.status,
          MessageStatus.bridgeAccepted,
        );

        mockBridge.emitMessage(
          const ConversationQueueMessage(
            sessionId: 's1',
            limit: 1,
            items: [
              QueuedInputItem(
                itemId: 'legacy-q1',
                text: 'Legacy queued follow up',
                createdAt: '2026-04-25T00:00:00.000Z',
              ),
            ],
          ),
          sessionId: 's1',
        );
        await Future.microtask(() {});

        expect(cubit.state.entries.whereType<UserChatEntry>(), isEmpty);
        expect(cubit.state.queuedInput?.itemId, 'legacy-q1');
        expect(cubit.state.queuedInput?.clientMessageId, clientMessageId);
        expect(
          cubit.state.queuedInput?.deliveryStage,
          QueuedInputDeliveryStage.bridgeAccepted,
        );
      },
    );

    test('ambiguous legacy queue text keeps every fact visible', () async {
      final cubit = createCubit('s1', provider: Provider.codex);
      addTearDown(cubit.close);
      await Future.microtask(() {});

      cubit.sendMessage('Same follow up');
      cubit.sendMessage('Same follow up');
      expect(cubit.state.entries.whereType<UserChatEntry>(), hasLength(2));

      mockBridge.emitMessage(
        const ConversationQueueMessage(
          sessionId: 's1',
          limit: 1,
          items: [
            QueuedInputItem(
              itemId: 'legacy-q1',
              text: 'Same follow up',
              createdAt: '2026-04-25T00:00:00.000Z',
            ),
          ],
        ),
        sessionId: 's1',
      );
      await Future.microtask(() {});

      expect(cubit.state.entries.whereType<UserChatEntry>(), hasLength(2));
      expect(cubit.state.queuedInput?.itemId, 'legacy-q1');
      expect(cubit.state.queuedInput?.clientMessageId, isNull);
    });

    test(
      'codex queued input update steer and cancel send client messages',
      () async {
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        const item = QueuedInputItem(
          itemId: 'q1',
          text: 'Original',
          createdAt: '2026-04-25T00:00:00.000Z',
        );

        await cubit.updateQueuedInput(item, 'Edited');
        var payload =
            jsonDecode(mockBridge.sentMessages.last.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'update_queued_input');
        expect(payload['itemId'], 'q1');
        expect(payload['text'], 'Edited');

        cubit.steerQueuedInput(item);
        payload =
            jsonDecode(mockBridge.sentMessages.last.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'steer_queued_input');
        expect(payload['itemId'], 'q1');

        await cubit.cancelQueuedInput(item);
        payload =
            jsonDecode(mockBridge.sentMessages.last.toJson())
                as Map<String, dynamic>;
        expect(payload['type'], 'cancel_queued_input');
        expect(payload['itemId'], 'q1');
      },
    );

    test(
      'offline codex queued input update and cancel mutate local pending input',
      () async {
        mockBridge.connected = false;
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Original offline');
        final item = cubit.state.queuedInput!;
        final clientMessageId = ChatSessionCubit.offlineQueuedClientMessageId(
          item,
        );

        await cubit.updateQueuedInput(item, 'Edited offline');
        expect(cubit.state.queuedInput?.text, 'Edited offline');
        expect(mockBridge.updatedOfflineInputs.single, {
          'sessionId': 's1',
          'clientMessageId': clientMessageId,
          'text': 'Edited offline',
          'skills': <Map<String, String>>[],
          'mentions': <Map<String, String>>[],
        });
        expect(
          mockBridge.sentMessages.map((message) => message.type),
          isNot(contains('update_queued_input')),
        );

        cubit.steerQueuedInput(cubit.state.queuedInput!);
        expect(
          mockBridge.sentMessages.map((message) => message.type),
          isNot(contains('steer_queued_input')),
        );

        await cubit.cancelQueuedInput(cubit.state.queuedInput!);
        expect(cubit.state.queuedInput, isNull);
        expect(mockBridge.canceledOfflineInputs.single, {
          'sessionId': 's1',
          'clientMessageId': clientMessageId,
        });
      },
    );

    test(
      'offline queue edit and cancel stay visible when reconnect won the race',
      () async {
        mockBridge.connected = false;
        final cubit = createCubit('s1', provider: Provider.codex);
        addTearDown(cubit.close);
        await Future.microtask(() {});

        cubit.sendMessage('Original offline');
        final item = cubit.state.queuedInput!;

        mockBridge.offlineUpdateSucceeds = false;
        expect(await cubit.updateQueuedInput(item, 'Too late edit'), isFalse);
        expect(cubit.state.queuedInput?.text, 'Original offline');

        mockBridge.offlineCancelSucceeds = false;
        expect(await cubit.cancelQueuedInput(item), isFalse);
        expect(cubit.state.queuedInput?.itemId, item.itemId);
      },
    );
  });

  group('StreamingStateCubit', () {
    test('initial state is empty', () {
      expect(streamingCubit.state.text, isEmpty);
      expect(streamingCubit.state.thinking, isEmpty);
      expect(streamingCubit.state.isStreaming, false);
    });

    test('appendText accumulates and sets isStreaming', () {
      streamingCubit.appendText('Hello ');
      streamingCubit.appendText('world');

      expect(streamingCubit.state.text, 'Hello world');
      expect(streamingCubit.state.isStreaming, true);
    });

    test('appendThinking accumulates', () {
      streamingCubit.appendThinking('Thinking...');
      streamingCubit.appendThinking(' more');

      expect(streamingCubit.state.thinking, 'Thinking... more');
    });

    test('reset clears everything', () {
      streamingCubit.appendText('text');
      streamingCubit.appendThinking('think');
      streamingCubit.reset();

      expect(streamingCubit.state.text, isEmpty);
      expect(streamingCubit.state.thinking, isEmpty);
      expect(streamingCubit.state.isStreaming, false);
    });
  });

  group('Permission mode initialization', () {
    test(
      'cubit created with initialPermissionMode reflects it immediately',
      () {
        final cubit = ChatSessionCubit(
          sessionId: 'pm-test',
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          initialPermissionMode: PermissionMode.bypassPermissions,
        );
        addTearDown(cubit.close);

        expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
      },
    );

    test(
      'cubit created with null initialPermissionMode defaults to defaultMode',
      () {
        final cubit = ChatSessionCubit(
          sessionId: 'pm-null',
          bridge: mockBridge,
          streamingCubit: streamingCubit,
        );
        addTearDown(cubit.close);

        expect(cubit.state.permissionMode, PermissionMode.defaultMode);
      },
    );

    test(
      'session_created message with permissionMode updates cubit state',
      () async {
        final cubit = ChatSessionCubit(
          sessionId: 'pm-update',
          bridge: mockBridge,
          streamingCubit: streamingCubit,
        );
        addTearDown(cubit.close);
        await Future.microtask(() {});

        expect(cubit.state.permissionMode, PermissionMode.defaultMode);

        const sessionCreated = SystemMessage(
          subtype: 'session_created',
          sessionId: 'pm-update',
          permissionMode: 'bypassPermissions',
        );
        mockBridge.emitMessage(sessionCreated, sessionId: 'pm-update');
        await Future.microtask(() {});

        expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
      },
    );

    test(
      'history message preserves initial permissionMode (does not reset)',
      () async {
        final cubit = ChatSessionCubit(
          sessionId: 'pm-history',
          bridge: mockBridge,
          streamingCubit: streamingCubit,
          initialPermissionMode: PermissionMode.bypassPermissions,
        );
        addTearDown(cubit.close);
        await Future.microtask(() {});

        final historyMsg = HistoryMessage(
          messages: [
            const StatusMessage(status: ProcessStatus.idle),
            AssistantServerMessage(
              message: AssistantMessage(
                id: 'a1',
                role: 'assistant',
                content: [TextContent(text: 'Hello!')],
                model: 'gpt-5-codex',
              ),
            ),
          ],
        );
        mockBridge.emitMessage(historyMsg, sessionId: 'pm-history');
        await Future.microtask(() {});

        expect(cubit.state.permissionMode, PermissionMode.bypassPermissions);
      },
    );
  });

  group('updateRecentPeekedFiles', () {
    test('moves reopened file to front without duplication', () {
      final updated = updateRecentPeekedFiles([
        'lib/main.dart',
        'lib/app.dart',
        'README.md',
      ], 'lib/app.dart');

      expect(updated, ['lib/app.dart', 'lib/main.dart', 'README.md']);
    });

    test('caps history at ten items', () {
      final updated = updateRecentPeekedFiles(
        List.generate(10, (i) => 'lib/file_$i.dart'),
        'lib/new.dart',
      );

      expect(updated.length, 10);
      expect(updated.first, 'lib/new.dart');
      expect(updated.last, 'lib/file_8.dart');
    });
  });
}
