import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/side_chat/widgets/persisted_side_chat_pane.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  _Bridge({required this.advertisedCapabilities});

  final Set<String> advertisedCapabilities;
  final sent = <ClientMessage>[];
  final localMessages = StreamController<LocalFeatureServerMessage>.broadcast(
    sync: true,
  );

  @override
  bool get isConnected => true;

  @override
  Set<String> get bridgeCapabilities => advertisedCapabilities;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => localMessages.stream.where((message) => message.sessionId == sessionId);

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  void dispose() {
    localMessages.close();
    super.dispose();
  }
}

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

void _completeLegacyOpen(_Bridge bridge, {String sideChatId = 'legacy-1'}) {
  final request = bridge.sent.lastWhere(
    (message) => _json(message)['type'] == 'open_side_chat',
  );
  bridge.localMessages.add(
    SideChatEventMessage(
      event: SideChatEventKind.opened,
      parentSessionId: 'parent-1',
      sideChatId: sideChatId,
      requestId: _json(request)['requestId'] as String,
    ),
  );
}

Future<DraftService> _drafts() async {
  SharedPreferences.setMockInitialValues({});
  return DraftService(await SharedPreferences.getInstance());
}

Widget _app(PersistedSideChatPane pane) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: pane),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('old Bridge directly uses the isolated legacy side chat', (
    tester,
  ) async {
    final bridge = _Bridge(advertisedCapabilities: const {});
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        PersistedSideChatPane(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          draftService: await _drafts(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('persisted_side_chat_legacy_fallback')),
      findsOneWidget,
    );
    expect(
      bridge.sent.map((message) => _json(message)['type']),
      isNot(contains('open_persisted_side_chat')),
    );
    expect(
      bridge.sent.map((message) => _json(message)['type']),
      contains('open_side_chat'),
    );

    _completeLegacyOpen(bridge);
    await tester.pump();
  });

  testWidgets('new Bridge creates a persisted child and keeps selected draft', (
    tester,
  ) async {
    final bridge = _Bridge(
      advertisedCapabilities: const {persistedSideChatCapability},
    );
    final drafts = await _drafts();
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        PersistedSideChatPane(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          draftService: drafts,
          initialSelection: 'first line\nsecond line',
        ),
      ),
    );

    final request = bridge.sent.singleWhere(
      (message) => _json(message)['type'] == 'open_persisted_side_chat',
    );
    final requestId = _json(request)['requestId'] as String;
    expect(
      find.byKey(const ValueKey('persisted_side_chat_loading')),
      findsOneWidget,
    );

    bridge.localMessages.add(
      PersistedSideChatOpenedMessage(
        parentSessionId: 'parent-1',
        requestId: requestId,
        childSessionId: 'child-1',
        projectPath: '/tmp/project',
      ),
    );
    expect(drafts.getDraft('child-1'), '> first line\n> second line\n\n');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit unsupported response falls back without retry loop', (
    tester,
  ) async {
    final bridge = _Bridge(
      advertisedCapabilities: const {persistedSideChatCapability},
    );
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        PersistedSideChatPane(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          draftService: await _drafts(),
        ),
      ),
    );
    final request = bridge.sent.singleWhere(
      (message) => _json(message)['type'] == 'open_persisted_side_chat',
    );
    bridge.localMessages.add(
      PersistedSideChatOpenedMessage(
        parentSessionId: 'parent-1',
        requestId: _json(request)['requestId'] as String,
        error: 'Not available',
        errorCode: 'unsupported_bridge',
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('persisted_side_chat_legacy_fallback')),
      findsOneWidget,
    );
    expect(
      bridge.sent.map((message) => _json(message)['type']),
      contains('open_side_chat'),
    );

    _completeLegacyOpen(bridge, sideChatId: 'legacy-2');
    await tester.pump();
  });
}
