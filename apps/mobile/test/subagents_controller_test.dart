import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/subagents/state/subagents_controller.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final tagged =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final connections = StreamController<BridgeConnectionState>.broadcast();
  final sessionLists = StreamController<List<SessionInfo>>.broadcast();
  final sent = <ClientMessage>[];
  bool connected = true;
  bool authoritative = false;
  Set<String> capabilities = const {};
  String? sourceId;

  @override
  bool get isConnected => connected;

  @override
  Stream<BridgeConnectionState> get connectionStatus => connections.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => sessionLists.stream;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      connected && authoritative;

  @override
  Set<String> get bridgeCapabilities => capabilities;

  @override
  String? get codexSourceId => sourceId;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => tagged.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  void send(ClientMessage message) => sent.add(message);

  void emit(LocalFeatureServerMessage message, {String? tag}) =>
      tagged.add((message, tag));

  void emitConnection(BridgeConnectionState state) => connections.add(state);

  void emitSessionList() => sessionLists.add(const []);

  @override
  void dispose() {
    tagged.close();
    connections.close();
    sessionLists.close();
    super.dispose();
  }
}

String _requestId(ClientMessage message) =>
    (jsonDecode(message.toJson()) as Map<String, dynamic>)['requestId']
        as String;

void main() {
  test('list requires exact session and latest request id', () async {
    final bridge = _Bridge();
    final controller = SubagentsController(sessionId: 's1', bridge: bridge);
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.refresh();
    final oldRequest = _requestId(bridge.sent.last);
    controller.refresh();
    expect(bridge.sent, hasLength(1));

    bridge.emit(
      SubagentListMessage(
        sessionId: 's1',
        requestId: oldRequest,
        subagents: const [SubagentInfo(threadId: 'first', status: 'done')],
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(bridge.sent, hasLength(2));
    final request = _requestId(bridge.sent.last);

    bridge.emit(
      SubagentListMessage(
        sessionId: 's1',
        requestId: oldRequest,
        subagents: const [SubagentInfo(threadId: 'stale', status: 'done')],
      ),
      tag: 's1',
    );
    bridge.emit(
      SubagentListMessage(
        sessionId: 'wrong',
        requestId: request,
        subagents: const [SubagentInfo(threadId: 'wrong', status: 'done')],
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.listLoading, isTrue);
    expect(controller.subagents.single.threadId, 'first');

    bridge.emit(
      SubagentListMessage(
        sessionId: 's1',
        requestId: request,
        subagents: const [SubagentInfo(threadId: 'current', status: 'running')],
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.listLoading, isFalse);
    expect(controller.subagents.single.threadId, 'current');
  });

  test('history requires a pending exact request', () async {
    final bridge = _Bridge();
    final controller = SubagentsController(sessionId: 's1', bridge: bridge);
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.loadHistory('child');
    final request = _requestId(bridge.sent.last);
    bridge.emit(
      const SubagentHistoryMessage(
        sessionId: 's1',
        requestId: 'out-of-order',
        threadId: 'child',
        messages: [UserInputMessage(text: 'stale')],
      ),
      tag: 's1',
    );
    bridge.emit(
      SubagentHistoryMessage(
        sessionId: 's1',
        requestId: request,
        threadId: 'child',
        messages: const [UserInputMessage(text: 'current')],
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.histories['child']?.messages.single,
      isA<UserInputMessage>(),
    );
    expect(
      (controller.histories['child']!.messages.single as UserInputMessage).text,
      'current',
    );
  });

  test(
    'list and history timeouts report unsupported and clear loading',
    () async {
      final bridge = _Bridge();
      final controller = SubagentsController(
        sessionId: 's1',
        bridge: bridge,
        requestTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.refresh();
      controller.loadHistory('child');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(controller.listLoading, isFalse);
      expect(controller.listError, 'unsupported');
      expect(controller.historyLoadingIds, isEmpty);
      expect(controller.historyErrors['child'], 'unsupported');
    },
  );

  test(
    'old Bridge errors clear only correlated list and history reads',
    () async {
      final bridge = _Bridge();
      final controller = SubagentsController(sessionId: 's1', bridge: bridge);
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.refresh();
      final listRequest = _requestId(bridge.sent.single);
      bridge.emit(
        const LocalFeatureRequestErrorMessage(
          featureId: 'subagents',
          ownerSessionId: 's1',
          requestType: 'get_subagents',
          requestId: 'wrong-request',
          message: 'get_subagents',
          errorCode: 'unsupported_message',
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.listLoading, isTrue);

      bridge.emit(
        LocalFeatureRequestErrorMessage(
          featureId: 'subagents',
          ownerSessionId: 's1',
          requestType: 'get_subagents',
          requestId: listRequest,
          message: 'get_subagents',
          errorCode: 'unsupported_message',
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.listLoading, isFalse);
      expect(controller.listError, 'unsupported');

      controller.loadHistory('child');
      final historyRequest = _requestId(bridge.sent.last);
      bridge.emit(
        LocalFeatureRequestErrorMessage(
          featureId: 'subagents',
          ownerSessionId: 's1',
          requestType: 'get_subagent_history',
          requestId: historyRequest,
          message: 'get_subagent_history',
          errorCode: 'unsupported_message',
        ),
        tag: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.historyLoadingIds, isEmpty);
      expect(controller.historyErrors['child'], 'unsupported');
    },
  );

  test('serializes list and history reads for one Bridge client', () async {
    final bridge = _Bridge();
    final controller = SubagentsController(sessionId: 's1', bridge: bridge);
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.refresh();
    final attachedListPayload =
        jsonDecode(bridge.sent.single.toJson()) as Map<String, dynamic>;
    expect(attachedListPayload['type'], 'get_subagents');
    expect(attachedListPayload['sessionId'], 's1');
    expect(attachedListPayload.containsKey('providerThreadId'), isFalse);
    expect(attachedListPayload.containsKey('codexSourceId'), isFalse);
    final listRequest = _requestId(bridge.sent.single);
    controller.loadHistory('child');
    expect(bridge.sent, hasLength(1));
    expect(controller.historyLoadingIds, contains('child'));

    bridge.emit(
      SubagentListMessage(
        sessionId: 's1',
        requestId: listRequest,
        subagents: const [SubagentInfo(threadId: 'child', status: 'done')],
      ),
      tag: 's1',
    );
    await Future<void>.delayed(Duration.zero);

    expect(bridge.sent, hasLength(2));
    final payload =
        jsonDecode(bridge.sent.last.toJson()) as Map<String, dynamic>;
    expect(payload['type'], 'get_subagent_history');
    expect(payload['threadId'], 'child');
  });

  test('disconnect clears pending reads and reconnect refreshes', () async {
    final bridge = _Bridge();
    final controller = SubagentsController(
      sessionId: 's1',
      bridge: bridge,
      requestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.refresh();
    bridge.connected = false;
    bridge.emitConnection(BridgeConnectionState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(controller.listLoading, isFalse);
    expect(controller.listError, 'bridge_disconnected');

    bridge.connected = true;
    bridge.emitConnection(BridgeConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(controller.listLoading, isTrue);
    expect(bridge.sent, hasLength(2));
  });

  test(
    'detached Desktop reads carry provider and authenticated source identities',
    () async {
      final bridge = _Bridge()
        ..authoritative = true
        ..capabilities = const {detachedSubagentsReadCapability}
        ..sourceId = 'source-1';
      final controller = SubagentsController(
        sessionId: 'pane-1',
        bridge: bridge,
        detachedProviderThreadId: 'provider-parent',
        detachedCodexSourceId: 'source-1',
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.refresh();
      final listPayload =
          jsonDecode(bridge.sent.single.toJson()) as Map<String, dynamic>;
      expect(listPayload, {
        'type': 'get_detached_subagents',
        'ownerSessionId': 'pane-1',
        'providerThreadId': 'provider-parent',
        'codexSourceId': 'source-1',
        'requestId': listPayload['requestId'],
      });
      expect(listPayload.containsKey('sessionId'), isFalse);

      bridge.emit(
        DetachedSubagentListMessage(
          ownerSessionId: 'pane-1',
          providerThreadId: 'provider-parent',
          codexSourceId: 'source-1',
          requestId: listPayload['requestId'] as String,
          subagents: const [SubagentInfo(threadId: 'child', status: 'done')],
        ),
        tag: 'pane-1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.subagents.single.threadId, 'child');
      expect(controller.listError, isNull);

      controller.loadHistory('child');
      final historyPayload =
          jsonDecode(bridge.sent.last.toJson()) as Map<String, dynamic>;
      expect(historyPayload['type'], 'get_detached_subagent_history');
      expect(historyPayload['ownerSessionId'], 'pane-1');
      expect(historyPayload['providerThreadId'], 'provider-parent');
      expect(historyPayload['codexSourceId'], 'source-1');
      expect(historyPayload.containsKey('sessionId'), isFalse);
    },
  );

  test('detached reads fail closed on source mismatch without sending', () {
    final bridge = _Bridge()
      ..authoritative = true
      ..capabilities = const {detachedSubagentsReadCapability}
      ..sourceId = 'authenticated-source';
    final controller = SubagentsController(
      sessionId: 'pane-1',
      bridge: bridge,
      detachedProviderThreadId: 'provider-parent',
      detachedCodexSourceId: 'other-source',
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.refresh();
    controller.loadHistory('child');

    expect(bridge.sent, isEmpty);
    expect(controller.listError, 'codex_source_mismatch');
    expect(controller.historyErrors['child'], 'codex_source_mismatch');
  });

  test(
    'source changes clear detached data and invalidate an older read',
    () async {
      final bridge = _Bridge()
        ..authoritative = true
        ..capabilities = const {detachedSubagentsReadCapability}
        ..sourceId = 'source-1';
      final controller = SubagentsController(
        sessionId: 'pane-1',
        bridge: bridge,
        detachedProviderThreadId: 'provider-parent',
        detachedCodexSourceId: 'source-1',
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.refresh();
      var requestId = _requestId(bridge.sent.last);
      bridge.emit(
        DetachedSubagentListMessage(
          ownerSessionId: 'pane-1',
          providerThreadId: 'provider-parent',
          codexSourceId: 'source-1',
          requestId: requestId,
          subagents: const [SubagentInfo(threadId: 'child', status: 'done')],
        ),
        tag: 'pane-1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.subagents, isNotEmpty);

      controller.refresh();
      requestId = _requestId(bridge.sent.last);
      bridge.sourceId = 'source-2';
      controller.refresh();
      bridge.emit(
        DetachedSubagentListMessage(
          ownerSessionId: 'pane-1',
          providerThreadId: 'provider-parent',
          codexSourceId: 'source-1',
          requestId: requestId,
          subagents: const [SubagentInfo(threadId: 'stale', status: 'done')],
        ),
        tag: 'pane-1',
      );
      await Future<void>.delayed(Duration.zero);

      expect(bridge.sent, hasLength(2));
      expect(controller.listError, 'codex_source_mismatch');
      expect(controller.subagents, isEmpty);
    },
  );

  test('new Mobile reports old Bridge as unsupported without fake data', () {
    final bridge = _Bridge()
      ..authoritative = true
      ..sourceId = 'source-1';
    final controller = SubagentsController(
      sessionId: 'pane-1',
      bridge: bridge,
      detachedProviderThreadId: 'provider-parent',
      detachedCodexSourceId: 'source-1',
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.refresh();

    expect(bridge.sent, isEmpty);
    expect(controller.listError, 'unsupported');
    expect(controller.subagents, isEmpty);
  });
}
