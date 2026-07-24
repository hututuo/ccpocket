import 'dart:async';

import 'package:ccpocket/features/side_chat/state/ephemeral_side_chat_registry_service.dart';
import 'package:ccpocket/features/side_chat/widgets/auxiliary_floating_dock.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  @override
  bool get isConnected => true;
}

class _Gateway implements EphemeralSideChatBridgeGateway {
  final messagesController =
      StreamController<LocalFeatureServerMessage>.broadcast(sync: true);

  @override
  bool isConnected = false;

  @override
  Set<String> capabilities = {ephemeralSideChatCapability};

  @override
  Stream<BridgeConnectionState> get connectionStatus => const Stream.empty();

  @override
  Stream<void> get capabilityChanges => const Stream.empty();

  @override
  Stream<LocalFeatureServerMessage> get messages => messagesController.stream;

  @override
  Stream<String> get stoppedSessions => const Stream.empty();

  @override
  void send(ClientMessage message) {}

  void dispose() => messagesController.close();
}

EphemeralSideChatEntry _entry() => EphemeralSideChatEntry(
  childSessionId: 'child-1',
  parentSessionId: 'parent-1',
  projectPath: '/tmp/project',
  status: 'running',
  createdAt: DateTime.utc(2026, 7, 25),
  lastActivityAt: DateTime.utc(2026, 7, 25, 0, 0, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens a retained side chat from the auxiliary sheet', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway();
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    gateway.messagesController.add(
      EphemeralSideChatRegistryMessage(entries: [_entry()]),
    );
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);
    String? openedParent;
    String? openedChild;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuxiliaryFloatingDock(
            sessionId: 'parent-1',
            bridgeService: bridge,
            registryService: registry,
            onOpenSideChat: (parentSessionId, entry) async {
              openedParent = parentSessionId;
              openedChild = entry?.childSessionId;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('auxiliary_floating_dock_tap')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('auxiliary_side_chat_child-1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('auxiliary_side_chat_child-1')));
    await tester.pumpAndSettle();
    expect(openedParent, 'parent-1');
    expect(openedChild, 'child-1');
  });

  testWidgets('snaps half off an edge and reveals before opening', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway();
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuxiliaryFloatingDock(
            sessionId: 'parent-1',
            bridgeService: bridge,
            registryService: registry,
            onOpenSideChat: (_, _) async {},
          ),
        ),
      ),
    );

    final dock = find.byKey(const ValueKey('auxiliary_floating_dock'));
    await tester.drag(dock, const Offset(-600, 60));
    await tester.pump();
    expect(tester.getTopLeft(dock).dx, lessThan(0));

    await tester.tap(find.byKey(const ValueKey('auxiliary_floating_dock_tap')));
    await tester.pump();
    expect(tester.getTopLeft(dock).dx, greaterThanOrEqualTo(0));
    expect(find.byType(TabBar), findsNothing);

    await tester.tap(find.byKey(const ValueKey('auxiliary_floating_dock_tap')));
    await tester.pumpAndSettle();
    expect(find.byType(TabBar), findsOneWidget);
  });
}
