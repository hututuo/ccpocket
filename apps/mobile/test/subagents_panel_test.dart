import 'dart:async';

import 'package:ccpocket/features/subagents/widgets/subagents_panel.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final tagged =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final sent = <ClientMessage>[];

  @override
  bool get isConnected => true;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => tagged.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  void send(ClientMessage message) => sent.add(message);

  void emit(LocalFeatureServerMessage message, String sessionId) =>
      tagged.add((message, sessionId));

  @override
  void dispose() {
    tagged.close();
    super.dispose();
  }
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: SizedBox(width: 430, height: 760, child: child)),
);

String _requestId(ClientMessage message) =>
    RegExp(r'"requestId":"([^"]+)"').firstMatch(message.toJson())!.group(1)!;

void main() {
  testWidgets('standalone panel opens read-only child history', (tester) async {
    final bridge = _Bridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      _app(SubagentsPanel(sessionId: 's1', bridgeService: bridge)),
    );
    await tester.pump();

    final listRequest = bridge.sent.last;
    expect(listRequest.type, 'get_subagents');
    bridge.emit(
      SubagentListMessage(
        sessionId: 's1',
        requestId: _requestId(listRequest),
        truncated: true,
        subagents: const [
          SubagentInfo(
            threadId: 'child-1',
            nickname: 'Aristotle',
            status: 'running',
          ),
        ],
      ),
      's1',
    );
    await tester.pump();
    expect(find.text('Aristotle'), findsOneWidget);
    expect(find.text('Bounded response: 1 shown.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('subagent_child-1')));
    await tester.pump();
    final historyRequest = bridge.sent.last;
    bridge.emit(
      SubagentHistoryMessage(
        sessionId: 's1',
        requestId: _requestId(historyRequest),
        threadId: 'child-1',
        messages: const [
          UserInputMessage(text: 'Inspect the protocol'),
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: [
                ToolUseContent(
                  id: 'tool-1',
                  name: 'Bash',
                  input: {'command': 'pwd'},
                ),
              ],
              model: 'codex',
            ),
          ),
        ],
      ),
      's1',
    );
    await tester.pump();
    expect(find.text('Inspect the protocol'), findsOneWidget);
    expect(find.text('User'), findsOneWidget);
    expect(find.textContaining('"command": "pwd"'), findsOneWidget);
  });
}
