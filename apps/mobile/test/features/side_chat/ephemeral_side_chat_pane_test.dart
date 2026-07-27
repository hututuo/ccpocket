import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/side_chat/state/ephemeral_side_chat_registry_service.dart';
import 'package:ccpocket/features/side_chat/widgets/ephemeral_side_chat_pane.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  _Bridge(this.capabilities);

  final Set<String> capabilities;
  final sent = <ClientMessage>[];
  final localMessages = StreamController<LocalFeatureServerMessage>.broadcast(
    sync: true,
  );

  @override
  bool get isConnected => true;

  @override
  Set<String> get bridgeCapabilities => capabilities;

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

class _Gateway implements EphemeralSideChatBridgeGateway {
  _Gateway(this.capabilities);

  @override
  Set<String> capabilities;
  final sent = <ClientMessage>[];
  final messagesController =
      StreamController<LocalFeatureServerMessage>.broadcast(sync: true);
  final capabilityController = StreamController<void>.broadcast(sync: true);

  @override
  bool isConnected = false;

  @override
  Stream<BridgeConnectionState> get connectionStatus => const Stream.empty();

  @override
  Stream<void> get capabilityChanges => capabilityController.stream;

  @override
  Stream<LocalFeatureServerMessage> get messages => messagesController.stream;

  @override
  Stream<String> get stoppedSessions => const Stream.empty();

  @override
  void send(ClientMessage message) => sent.add(message);

  void dispose() {
    messagesController.close();
    capabilityController.close();
  }
}

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

EphemeralSideChatEntry _entry() => EphemeralSideChatEntry(
  childSessionId: 'child-1',
  parentSessionId: 'parent-1',
  projectPath: '/tmp/project',
  status: 'idle',
  createdAt: DateTime.utc(2026, 7, 25),
  lastActivityAt: DateTime.utc(2026, 7, 25, 0, 0, 1),
);

Future<DraftService> _drafts() async {
  SharedPreferences.setMockInitialValues({});
  return DraftService(await SharedPreferences.getInstance());
}

Widget _app(EphemeralSideChatPane pane) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: pane),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uses the official registry and preserves selected text', (
    tester,
  ) async {
    final gateway = _Gateway({ephemeralSideChatCapability});
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    final bridge = _Bridge({ephemeralSideChatCapability});
    final drafts = await _drafts();
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        EphemeralSideChatPane(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          registryService: registry,
          draftService: drafts,
          initialSelection: 'first line\nsecond line',
        ),
      ),
    );
    await tester.pump();

    final refresh = gateway.sent.singleWhere(
      (message) => _json(message)['type'] == 'list_ephemeral_side_chats',
    );
    gateway.messagesController.add(
      EphemeralSideChatRegistryMessage(
        requestId: _json(refresh)['requestId'] as String,
        entries: const [],
      ),
    );
    await tester.pump();
    final open = gateway.sent.singleWhere(
      (message) => _json(message)['type'] == 'open_ephemeral_side_chat',
    );
    expect(
      gateway.sent.map((message) => _json(message)['type']),
      isNot(contains('open_persisted_side_chat')),
    );
    gateway.messagesController.add(
      EphemeralSideChatOpenedMessage(
        parentSessionId: 'parent-1',
        requestId: _json(open)['requestId'] as String,
        entry: _entry(),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(drafts.getDraft('child-1'), '> first line\n> second line\n\n');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reopens a registry child without creating another fork', (
    tester,
  ) async {
    final gateway = _Gateway({ephemeralSideChatCapability});
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    final bridge = _Bridge({ephemeralSideChatCapability});
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);
    gateway.messagesController.add(
      EphemeralSideChatRegistryMessage(entries: [_entry()]),
    );

    await tester.pumpWidget(
      _app(
        EphemeralSideChatPane(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          registryService: registry,
          draftService: await _drafts(),
          sessionBuilder: (entry) => Text(
            entry.childSessionId,
            key: const ValueKey('test_ephemeral_session'),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('test_ephemeral_session')),
      findsOneWidget,
    );
    expect(
      gateway.sent.map((message) => _json(message)['type']),
      isNot(contains('open_ephemeral_side_chat')),
    );
  });

  testWidgets('old Bridge fails closed instead of opening a different chat', (
    tester,
  ) async {
    final gateway = _Gateway({});
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    final bridge = _Bridge({});
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        EphemeralSideChatPane(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          registryService: registry,
          draftService: await _drafts(),
          sessionBuilder: (entry) => Text(entry.childSessionId),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Update the Bridge to use side chat.'), findsOneWidget);
    expect(
      bridge.sent.map((message) => _json(message)['type']),
      isNot(contains('open_side_chat')),
    );
  });

  testWidgets('late capability negotiation opens the official side chat', (
    tester,
  ) async {
    final gateway = _Gateway({});
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    final bridge = _Bridge({});
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      _app(
        EphemeralSideChatPane(
          parentSessionId: 'parent-1',
          bridgeService: bridge,
          registryService: registry,
          draftService: await _drafts(),
          sessionBuilder: (entry) => Text(entry.childSessionId),
        ),
      ),
    );
    await tester.pump();

    expect(
      gateway.sent.map((message) => _json(message)['type']),
      isNot(contains('open_ephemeral_side_chat')),
    );

    gateway.capabilities = {ephemeralSideChatCapability};
    gateway.capabilityController.add(null);
    await tester.pump();

    final refresh = gateway.sent.singleWhere(
      (message) => _json(message)['type'] == 'list_ephemeral_side_chats',
    );
    gateway.messagesController.add(
      EphemeralSideChatRegistryMessage(
        requestId: _json(refresh)['requestId'] as String,
        entries: const [],
      ),
    );
    await tester.pump();
    expect(
      gateway.sent.map((message) => _json(message)['type']),
      contains('open_ephemeral_side_chat'),
    );
    expect(
      gateway.sent.map((message) => _json(message)['type']),
      isNot(contains('open_side_chat')),
    );
    final open = gateway.sent.singleWhere(
      (message) => _json(message)['type'] == 'open_ephemeral_side_chat',
    );
    gateway.messagesController.add(
      EphemeralSideChatOpenedMessage(
        parentSessionId: 'parent-1',
        requestId: _json(open)['requestId'] as String,
        entry: _entry(),
      ),
    );
    await tester.pump();
  });
}
