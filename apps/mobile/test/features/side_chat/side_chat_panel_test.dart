import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/side_chat/side_chat_selection_action.dart';
import 'package:ccpocket/features/side_chat/l10n/side_chat_strings.dart';
import 'package:ccpocket/features/side_chat/state/side_chat_controller.dart';
import 'package:ccpocket/features/side_chat/widgets/side_chat_panel.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:ccpocket/widgets/chat_selection_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final events =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final sent = <ClientMessage>[];

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => events.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  bool get isConnected => true;

  @override
  void send(ClientMessage message) => sent.add(message);

  void emit(SideChatEventMessage event) =>
      events.add((event, event.parentSessionId));

  @override
  void dispose() {
    events.close();
    super.dispose();
  }
}

Map<String, dynamic> _payload(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

String Function() _ids() {
  var next = 0;
  return () => 'id-${++next}';
}

void main() {
  test('old Bridge errors use feature-local readable copy', () {
    expect(
      SideChatStrings.forLocale(
        const Locale('zh'),
      ).errorFor('bridge_update_required', 'open_side_chat'),
      '请更新 Bridge 后再使用侧边聊天。',
    );
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('selection action delegates only the bounded selected text', (
    tester,
  ) async {
    ChatSelectionAction? action;
    String? openedWith;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            action = createSideChatSelectionAction(
              context: context,
              onOpen: (value) => openedWith = value,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    action!.onSelected('selected text');
    expect(action!.label, 'Open side chat with selected text');
    expect(openedWith, 'selected text');
  });

  testWidgets('prefills without sending and clears only after exact ack', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final drafts = DraftService(await SharedPreferences.getInstance());
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: drafts,
      createId: _ids(),
    );
    addTearDown(() {
      controller.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SideChatPanel(
            parentSessionId: 'parent-1',
            bridgeService: bridge,
            draftService: drafts,
            controller: controller,
            initialSelection: 'first line\nsecond line',
            selectionRevision: 1,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(bridge.sent.map((message) => message.type), ['open_side_chat']);
    expect(
      drafts.getDraft(SideChatController.draftKeyFor('parent-1')),
      '> first line\n> second line\n\n',
    );
    expect(drafts.getDraft('parent-1'), isNull);
    expect(
      find.text(
        'Side chats are not saved; closing or reconnecting starts with an empty transcript. File changes remain shared in the same worktree.',
      ),
      findsOneWidget,
    );

    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await tester.pump();
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('side_chat_input')),
    );
    expect(input.controller!.text, '> first line\n> second line\n\n');

    await tester.tap(find.byKey(const ValueKey('side_chat_send')));
    await tester.pump();
    expect(bridge.sent.map((message) => message.type), [
      'open_side_chat',
      'side_chat_input',
    ]);
    expect(input.controller!.text, isNotEmpty);

    final sent = _payload(bridge.sent.last);
    bridge.emit(
      SideChatEventMessage(
        event: SideChatEventKind.inputAccepted,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: sent['requestId'] as String,
        clientMessageId: sent['clientMessageId'] as String,
      ),
    );
    await tester.pump();
    expect(input.controller!.text, isEmpty);
    expect(drafts.getDraft(SideChatController.draftKeyFor('parent-1')), isNull);
  });

  testWidgets('close then reopen creates a fresh correlated child request', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final drafts = DraftService(await SharedPreferences.getInstance());
    final bridge = _Bridge();
    final controller = SideChatController(
      parentSessionId: 'parent-1',
      bridge: bridge,
      draftService: drafts,
      createId: _ids(),
    );
    addTearDown(() {
      controller.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SideChatPanel(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          draftService: drafts,
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    bridge.emit(
      const SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: 'id-1',
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('side_chat_close')));
    await tester.pump();
    final close = _payload(bridge.sent.last);
    expect(close['type'], 'close_side_chat');
    bridge.emit(
      SideChatEventMessage(
        event: SideChatEventKind.closed,
        parentSessionId: 'parent-1',
        sideChatId: 'side-1',
        requestId: close['requestId'] as String,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('side_chat_reopen')));
    await tester.pump();
    expect(_payload(bridge.sent.last)['type'], 'open_side_chat');
    expect(_payload(bridge.sent.last)['requestId'], isNot('id-1'));
    final reopen = _payload(bridge.sent.last);
    bridge.emit(
      SideChatEventMessage(
        event: SideChatEventKind.opened,
        parentSessionId: 'parent-1',
        sideChatId: 'side-2',
        requestId: reopen['requestId'] as String,
      ),
    );
    await tester.pump();
  });
}
