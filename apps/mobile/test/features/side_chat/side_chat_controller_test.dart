import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/side_chat/state/side_chat_controller.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final events =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final connections = StreamController<BridgeConnectionState>.broadcast();
  final sent = <ClientMessage>[];
  bool connected = true;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => events.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  Stream<BridgeConnectionState> get connectionStatus => connections.stream;

  @override
  bool get isConnected => connected;

  @override
  void send(ClientMessage message) => sent.add(message);

  void emit(SideChatEventMessage event) =>
      events.add((event, event.parentSessionId));

  void setConnection(BridgeConnectionState state) {
    connected = state == BridgeConnectionState.connected;
    connections.add(state);
  }

  @override
  void dispose() {
    events.close();
    connections.close();
    super.dispose();
  }
}

Map<String, dynamic> _payload(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

String Function() _ids() {
  var next = 0;
  return () => 'id-${++next}';
}

Future<DraftService> _draftService([
  Map<String, Object> values = const {},
]) async {
  SharedPreferences.setMockInitialValues(values);
  return DraftService(await SharedPreferences.getInstance());
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closes an open race as soon as the correlated child arrives', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      requestTimeout: const Duration(milliseconds: 100),
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    expect(_payload(bridge.sent.single)['type'], 'open_side_chat');
    controller.close();
    expect(controller.lifecycle, SideChatLifecycle.closing);
    expect(bridge.sent, hasLength(1));

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await _flush();
    expect(_payload(bridge.sent.last), {
      'type': 'close_side_chat',
      'parentSessionId': 'parent-1',
      'sideChatId': 'side-1',
      'requestId': 'id-2',
    });

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.closed,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-2',
      ),
    );
    await _flush();
    expect(controller.lifecycle, SideChatLifecycle.closed);
    expect(controller.sideChatId, isNull);
  });

  test(
    'correlates send ack and error while preserving edited drafts',
    () async {
      final bridge = _Bridge();
      final drafts = await _draftService({'draft_v1_parent-1': 'main draft'});
      final controller = SideChatController(
        parentSessionId: 'parent-1',
        bridge: bridge,
        draftService: drafts,
        createId: _ids(),
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.open();
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.opened,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'id-1',
        ),
      );
      await _flush();
      controller.updateDraft('first prompt');
      expect(controller.sendDraft(), isTrue);
      expect(controller.entries.single.delivery, SideChatEntryDelivery.sending);
      expect(drafts.getDraft('parent-1'), 'main draft');
      expect(
        drafts.getDraft(SideChatController.draftKeyFor('parent-1')),
        'first prompt',
      );

      controller.updateDraft('edited while sending');
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.inputAccepted,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'id-2',
          clientMessageId: 'id-3',
        ),
      );
      await _flush();
      expect(controller.entries.single.delivery, SideChatEntryDelivery.sent);
      expect(controller.draft, 'edited while sending');

      expect(controller.sendDraft(), isTrue);
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.error,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'id-4',
          clientMessageId: 'id-5',
          error: SideChatErrorPayload(code: 'input_failed', message: 'Nope'),
        ),
      );
      await _flush();
      expect(controller.entries.last.delivery, SideChatEntryDelivery.failed);
      expect(controller.draft, 'edited while sending');
      expect(controller.errorMessage, 'Nope');
    },
  );

  test('keeps queued input pending until delivery is confirmed', () async {
    final bridge = _Bridge();
    final drafts = await _draftService();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: drafts,
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await _flush();
    controller.updateDraft('queued prompt');
    expect(controller.sendDraft(), isTrue);

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.inputAccepted,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-2',
        clientMessageId: 'id-3',
        queued: true,
      ),
    );
    await _flush();
    expect(controller.entries.single.delivery, SideChatEntryDelivery.sending);
    expect(controller.draft, 'queued prompt');
    expect(
      drafts.getDraft(SideChatController.draftKeyFor('parent-1')),
      'queued prompt',
    );

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.inputAccepted,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-2',
        clientMessageId: 'id-3',
      ),
    );
    await _flush();
    expect(controller.entries.single.delivery, SideChatEntryDelivery.sent);
    expect(controller.draft, isEmpty);
    expect(drafts.getDraft(SideChatController.draftKeyFor('parent-1')), isNull);
  });

  test('marks a queued input failed when delivery later fails', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await _flush();
    controller.updateDraft('queued prompt');
    controller.sendDraft();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.inputAccepted,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-2',
        clientMessageId: 'id-3',
        queued: true,
      ),
    );
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.error,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-2',
        clientMessageId: 'id-3',
        error: SideChatErrorPayload(
          code: 'side_chat_input_not_delivered',
          message: 'Child exited before delivery',
        ),
      ),
    );
    await _flush();

    expect(controller.entries.single.delivery, SideChatEntryDelivery.failed);
    expect(controller.draft, 'queued prompt');
    expect(controller.errorCode, 'side_chat_input_not_delivered');
  });

  test('ignores stale parent, open request, side chat, and ack ids', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'stale',
        requestId: 'wrong',
      ),
    );
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'other',
        sideChatId: 'wrong-parent',
        requestId: 'id-1',
      ),
    );
    await _flush();
    expect(controller.lifecycle, SideChatLifecycle.opening);

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await _flush();
    controller.updateDraft('prompt');
    controller.sendDraft();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.inputAccepted,
        parentSessionId: 'parent-1',
        sideChatId: 'wrong-side',
        requestId: 'id-2',
        clientMessageId: 'id-3',
      ),
    );
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.inputAccepted,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-2',
        clientMessageId: 'wrong-client',
      ),
    );
    await _flush();
    expect(controller.entries.single.delivery, SideChatEntryDelivery.sending);
  });

  test('handles correlated open errors without waiting for timeout', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      requestTimeout: const Duration(seconds: 5),
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.error,
        parentSessionId: 'parent-1',
        requestId: 'id-1',
        error: SideChatErrorPayload(
          code: 'fork_failed',
          message: 'Could not fork',
        ),
      ),
    );
    await _flush();
    expect(controller.lifecycle, SideChatLifecycle.failed);
    expect(controller.errorCode, 'fork_failed');
    expect(controller.errorMessage, 'Could not fork');
  });

  test(
    'handles correlated old Bridge errors without touching stale ids',
    () async {
      final bridge = _Bridge();
      final controller = SideChatController(
        parentSessionId: 'parent-1',
        bridge: bridge,
        draftService: await _draftService(),
        createId: _ids(),
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.open();
      bridge.events.add((
        const LocalFeatureRequestErrorMessage(
          featureId: 'side_chat',
          ownerSessionId: 'parent-1',
          requestType: 'open_side_chat',
          requestId: 'stale',
          message: 'open_side_chat',
          errorCode: 'unsupported_message',
        ),
        'parent-1',
      ));
      await _flush();
      expect(controller.lifecycle, SideChatLifecycle.opening);

      bridge.events.add((
        const LocalFeatureRequestErrorMessage(
          featureId: 'side_chat',
          ownerSessionId: 'parent-1',
          requestType: 'open_side_chat',
          requestId: 'id-1',
          message: 'open_side_chat',
          errorCode: 'unsupported_message',
        ),
        'parent-1',
      ));
      await _flush();
      expect(controller.lifecycle, SideChatLifecycle.failed);
      expect(controller.errorCode, 'bridge_update_required');
    },
  );

  test(
    'replaces streamed messages and matching local user echoes by id',
    () async {
      final bridge = _Bridge();
      final controller = SideChatController(
        parentSessionId: 'parent-1',
        bridge: bridge,
        draftService: await _draftService(),
        createId: _ids(),
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.open();
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.opened,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'id-1',
        ),
      );
      await _flush();
      controller.updateDraft('hello');
      controller.sendDraft();
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.message,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          message: SideChatTranscriptMessage(
            id: 'id-3',
            role: 'user',
            text: 'hello',
          ),
        ),
      );
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.message,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          message: SideChatTranscriptMessage(
            id: 'assistant-1',
            role: 'assistant',
            text: 'partial',
          ),
        ),
      );
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.message,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          message: SideChatTranscriptMessage(
            id: 'assistant-1',
            role: 'assistant',
            text: 'complete',
          ),
        ),
      );
      await _flush();

      expect(controller.entries, hasLength(2));
      expect(controller.entries.first.text, 'hello');
      expect(controller.entries.last.text, 'complete');
    },
  );

  test('bounds the in-memory isolated transcript', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await _flush();
    for (var index = 0; index < sideChatMaxTranscriptEntries + 5; index++) {
      bridge.emit(
        SideChatEventMessage(
          event: SideChatEventKind.message,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          message: SideChatTranscriptMessage(
            id: 'message-$index',
            role: 'assistant',
            text: '$index',
          ),
        ),
      );
    }
    await _flush();

    expect(controller.entries, hasLength(sideChatMaxTranscriptEntries));
    expect(controller.entries.first.id, 'message-5');
  });

  test('bounds the isolated transcript by total characters', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await _flush();
    const chunkCharacters = 600000;
    final chunk = List.filled(chunkCharacters - 1, 'x').join();
    for (var index = 0; index < 4; index++) {
      bridge.emit(
        SideChatEventMessage(
          event: SideChatEventKind.message,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          message: SideChatTranscriptMessage(
            id: 'large-$index',
            role: 'assistant',
            text: '$index$chunk',
          ),
        ),
      );
    }
    await _flush();

    expect(controller.entries.map((entry) => entry.id), [
      'large-1',
      'large-2',
      'large-3',
    ]);
    expect(
      controller.entries.fold<int>(0, (sum, entry) => sum + entry.text.length),
      lessThanOrEqualTo(sideChatMaxTranscriptCharacters),
    );
  });

  test(
    'disconnect invalidates the child and reconnect opens a new one',
    () async {
      final bridge = _Bridge();
      final controller = SideChatController(
        parentSessionId: 'parent-1',
        bridge: bridge,
        draftService: await _draftService(),
        createId: _ids(),
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.open();
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.opened,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'id-1',
        ),
      );
      await _flush();

      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.message,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          message: SideChatTranscriptMessage(
            id: 'old-answer',
            role: 'assistant',
            text: 'old child context',
          ),
        ),
      );
      await _flush();
      expect(controller.entries, isNotEmpty);

      bridge.setConnection(BridgeConnectionState.disconnected);
      await _flush();
      expect(controller.lifecycle, SideChatLifecycle.disconnected);
      expect(controller.sideChatId, isNull);
      expect(controller.entries, isNotEmpty);

      bridge.setConnection(BridgeConnectionState.connected);
      await _flush();
      expect(_payload(bridge.sent.last)['type'], 'open_side_chat');
      expect(_payload(bridge.sent.last)['requestId'], 'id-2');

      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.opened,
          parentSessionId: 'parent-1',
          sideChatId: 'side-2',
          requestId: 'id-2',
        ),
      );
      await _flush();
      expect(controller.entries, isEmpty);

      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.status,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          status: 'running',
        ),
      );
      await _flush();
      expect(controller.processStatus, 'idle');
    },
  );

  test('starts an empty transcript after a child exit reopens', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      createId: _ids(),
    );
    addTearDown(controller.dispose);
    addTearDown(bridge.dispose);

    controller.open();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.message,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        message: SideChatTranscriptMessage(
          id: 'old-answer',
          role: 'assistant',
          text: 'old child context',
        ),
      ),
    );
    await _flush();

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.closed,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
      ),
    );
    await _flush();
    expect(_payload(bridge.sent.last)['type'], 'open_side_chat');
    expect(_payload(bridge.sent.last)['requestId'], 'id-2');
    expect(controller.entries, isNotEmpty);

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-2',
        requestId: 'id-2',
      ),
    );
    await _flush();
    expect(controller.entries, isEmpty);
  });

  test(
    'sends permission, multi-question answer, and interrupt canonically',
    () async {
      final bridge = _Bridge();
      final controller = SideChatController(
        parentSessionId: 'parent-1',
        bridge: bridge,
        draftService: await _draftService(),
        createId: _ids(),
      );
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);

      controller.open();
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.opened,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          requestId: 'id-1',
        ),
      );
      await _flush();
      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.permissionRequest,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          permission: SideChatPermissionRequest(
            requestId: 'permission-1',
            toolName: 'Bash',
            input: {'command': 'pwd'},
          ),
        ),
      );
      await _flush();
      controller.respondPermission(SideChatPermissionDecision.allowAlways);
      expect(_payload(bridge.sent.last), {
        'type': 'side_chat_permission_response',
        'parentSessionId': 'parent-1',
        'sideChatId': 'side-1',
        'requestId': 'id-2',
        'permissionRequestId': 'permission-1',
        'decision': 'allow_always',
      });

      bridge.emit(
        const SideChatEventMessage(
          event: SideChatEventKind.question,
          parentSessionId: 'parent-1',
          sideChatId: 'side-1',
          question: SideChatQuestionRequest(
            requestId: 'question-1',
            questions: [
              {'id': 'q1', 'question': 'Choose?'},
            ],
          ),
        ),
      );
      await _flush();
      controller.answerQuestion(
        'question-1',
        '{"questions":[],"answers":{"q1":"A"}}',
      );
      expect(_payload(bridge.sent.last)['type'], 'side_chat_answer');
      expect(
        _payload(bridge.sent.last)['answer'],
        '{"questions":[],"answers":{"q1":"A"}}',
      );

      controller.interrupt();
      expect(_payload(bridge.sent.last)['type'], 'side_chat_interrupt');
    },
  );

  test('dispose during open closes the late correlated child', () async {
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: await _draftService(),
      requestTimeout: const Duration(milliseconds: 100),
      createId: _ids(),
    );
    addTearDown(bridge.dispose);

    controller.open();
    controller.dispose();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'late-side',
        requestId: 'id-1',
      ),
    );
    await _flush();
    expect(_payload(bridge.sent.last)['type'], 'close_side_chat');
    expect(_payload(bridge.sent.last)['sideChatId'], 'late-side');
  });
}
