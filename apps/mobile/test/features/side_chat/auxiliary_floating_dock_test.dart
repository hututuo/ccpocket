import 'dart:async';

import 'package:ccpocket/features/side_chat/state/ephemeral_side_chat_registry_service.dart';
import 'package:ccpocket/features/side_chat/widgets/auxiliary_floating_dock.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String? logicalConnectionIdentity;

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

EphemeralSideChatEntry _entry({
  String childSessionId = 'child-1',
  String parentSessionId = 'parent-1',
}) => EphemeralSideChatEntry(
  childSessionId: childSessionId,
  parentSessionId: parentSessionId,
  projectPath: '/tmp/project',
  status: 'running',
  createdAt: DateTime.utc(2026, 7, 25),
  lastActivityAt: DateTime.utc(2026, 7, 25, 0, 0, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('expands inline and opens a retained side chat', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway();
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    gateway.messagesController.add(
      EphemeralSideChatRegistryMessage(
        entries: [
          _entry(),
          _entry(childSessionId: 'child-2', parentSessionId: 'parent-2'),
        ],
      ),
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

    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('auxiliary_floating_dock_tap')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('auxiliary_floating_panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('auxiliary_side_chat_child-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('auxiliary_side_chat_child-2')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('auxiliary_side_chat_child-1')));
    await tester.pumpAndSettle();
    expect(openedParent, 'parent-1');
    expect(openedChild, 'child-1');
  });

  testWidgets(
    'keeps free placement across collapse and docks only past the threshold',
    (tester) async {
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
      await tester.drag(dock, const Offset(-260, 60));
      await tester.pump();
      final freePosition = tester.getTopLeft(dock);
      expect(freePosition.dx, inInclusiveRange(400, 600));

      await tester.tap(
        find.byKey(const ValueKey('auxiliary_floating_dock_tap')),
      );
      await tester.pumpAndSettle();
      expect(dock, findsNothing);
      expect(find.byType(TabBar), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('auxiliary_floating_panel_collapse')),
      );
      await tester.pump();
      expect(tester.getTopLeft(dock).dx, closeTo(freePosition.dx, 1));
      expect(tester.getTopLeft(dock).dy, closeTo(freePosition.dy, 1));

      await tester.drag(dock, Offset(-(freePosition.dx + 8), 0));
      await tester.pump();
      expect(tester.getTopLeft(dock).dx, closeTo(12, 1));

      await tester.drag(dock, const Offset(-25, 0));
      await tester.pump();
      expect(tester.getTopLeft(dock).dx, closeTo(-24, 1));

      await tester.drag(dock, const Offset(140, 0));
      await tester.pump();
      expect(tester.getTopLeft(dock).dx, inInclusiveRange(100, 140));

      await tester.tap(
        find.byKey(const ValueKey('auxiliary_floating_dock_tap')),
      );
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('auxiliary_floating_panel'));
      final initialPanelLeft = tester.getTopLeft(panel).dx;

      await tester.drag(
        find.byKey(const ValueKey('auxiliary_floating_panel_header')),
        const Offset(30, 60),
      );
      await tester.pump();
      expect(tester.getTopLeft(panel).dx, closeTo(initialPanelLeft, 1));
      expect(tester.getTopLeft(panel).dx, lessThan(700));

      await tester.drag(
        find.byKey(const ValueKey('auxiliary_floating_panel_header')),
        const Offset(120, 0),
      );
      await tester.pump();
      expect(tester.getTopLeft(panel).dx, greaterThan(700));

      final header = find.byKey(
        const ValueKey('auxiliary_floating_panel_header'),
      );
      final pullGesture = await tester.startGesture(
        Offset(778, tester.getTopLeft(header).dy + 20),
      );
      await pullGesture.moveBy(const Offset(-700, 0));
      await pullGesture.up();
      await tester.pump();
      expect(tester.getTopLeft(panel).dx, inInclusiveRange(10, 430));

      await tester.tap(
        find.byKey(const ValueKey('auxiliary_floating_panel_collapse')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('auxiliary_floating_dock')),
        findsOneWidget,
      );
      expect(panel, findsNothing);
    },
  );

  testWidgets('restores the snapped handle placement after reconstruction', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway();
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);

    Widget buildDock() => MaterialApp(
      home: Scaffold(
        body: AuxiliaryFloatingDock(
          sessionId: 'parent-1',
          bridgeService: bridge,
          registryService: registry,
          onOpenSideChat: (_, _) async {},
        ),
      ),
    );

    await tester.pumpWidget(buildDock());
    await tester.pumpAndSettle();
    var dock = find.byKey(const ValueKey('auxiliary_floating_dock'));
    final initialLeft = tester.getTopLeft(dock).dx;
    await tester.drag(dock, Offset(-(initialLeft + 13), 100));
    await tester.pumpAndSettle();
    final savedTop = tester.getTopLeft(dock).dy;
    expect(tester.getTopLeft(dock).dx, lessThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildDock());
    await tester.pumpAndSettle();

    dock = find.byKey(const ValueKey('auxiliary_floating_dock'));
    expect(tester.getTopLeft(dock).dx, lessThan(0));
    expect(tester.getTopLeft(dock).dy, closeTo(savedTop, 1));
  });

  testWidgets('restores a freely placed handle after reconstruction', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway();
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);

    Widget buildDock() => MaterialApp(
      home: Scaffold(
        body: AuxiliaryFloatingDock(
          sessionId: 'parent-1',
          bridgeService: bridge,
          registryService: registry,
          onOpenSideChat: (_, _) async {},
        ),
      ),
    );

    await tester.pumpWidget(buildDock());
    await tester.pumpAndSettle();
    var dock = find.byKey(const ValueKey('auxiliary_floating_dock'));
    await tester.drag(dock, const Offset(-250, 80));
    await tester.pumpAndSettle();
    final savedPosition = tester.getTopLeft(dock);
    expect(savedPosition.dx, inInclusiveRange(400, 600));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildDock());
    await tester.pumpAndSettle();

    dock = find.byKey(const ValueKey('auxiliary_floating_dock'));
    expect(tester.getTopLeft(dock).dx, closeTo(savedPosition.dx, 1));
    expect(tester.getTopLeft(dock).dy, closeTo(savedPosition.dy, 1));
  });

  testWidgets('expanded panel does not block the conversation outside its bounds', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway();
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    gateway.isConnected = true;
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);
    var backgroundTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 8,
                top: 8,
                child: TextButton(
                  key: const ValueKey('conversation_background_action'),
                  onPressed: () => backgroundTaps += 1,
                  child: const Text('Conversation action'),
                ),
              ),
              Positioned.fill(
                child: AuxiliaryFloatingDock(
                  sessionId: 'parent-1',
                  bridgeService: bridge,
                  registryService: registry,
                  onOpenSideChat: (_, _) async {},
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('auxiliary_floating_dock_tap')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('auxiliary_floating_panel')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('conversation_background_action')),
    );
    await tester.pump();
    expect(backgroundTaps, 1);
    expect(
      find.byKey(const ValueKey('auxiliary_floating_panel')),
      findsOneWidget,
    );
  });
}
