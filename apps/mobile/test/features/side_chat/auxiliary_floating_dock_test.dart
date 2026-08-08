import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/side_chat/state/ephemeral_side_chat_registry_service.dart';
import 'package:ccpocket/features/side_chat/widgets/auxiliary_floating_dock.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final tagged =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final sent = <ClientMessage>[];

  @override
  bool get isConnected => true;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection => true;

  @override
  Set<String> get bridgeCapabilities => const {detachedSubagentsReadCapability};

  @override
  String? get codexSourceId => 'source-1';

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => tagged.stream
      .where((pair) => pair.$2 == sessionId)
      .map((pair) => pair.$1);

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  void dispose() {
    tagged.close();
    super.dispose();
  }
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
  String? parentProviderSessionId,
}) => EphemeralSideChatEntry(
  childSessionId: childSessionId,
  parentSessionId: parentSessionId,
  parentProviderSessionId: parentProviderSessionId,
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

  testWidgets('expands inline and opens a retained side chat', (tester) async {
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
    String? openedProviderParent;
    String? openedChild;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuxiliaryFloatingDock(
            sessionId: 'parent-1',
            bridgeService: bridge,
            registryService: registry,
            onOpenSideChat:
                (parentSessionId, parentProviderSessionId, entry) async {
                  openedParent = parentSessionId;
                  openedProviderParent = parentProviderSessionId;
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
    expect(openedProviderParent, 'parent-1');
    expect(openedChild, 'child-1');
  });

  testWidgets('keeps durable todos isolated and sends through the callback', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway()..isConnected = true;
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);
    final sent = <String>[];
    const sourceA = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-todo',
      codexSourceId: 'source-a',
    );
    const sourceB = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-todo',
      codexSourceId: 'source-b',
    );

    Widget buildDock(String durableId, {BridgeDataSourceIdentity? source}) =>
        MaterialApp(
          home: Scaffold(
            body: AuxiliaryFloatingDock(
              sessionId: 'runtime-$durableId',
              durableSessionId: durableId,
              parentProviderSessionId: durableId,
              todoDataSourceIdentity: source ?? sourceA,
              bridgeService: bridge,
              registryService: registry,
              onOpenSideChat: (_, _, _) async {},
              onSendTodo: (text) {
                sent.add(text);
                return true;
              },
            ),
          ),
        );

    await tester.pumpWidget(buildDock('durable-main'));
    await tester.tap(find.byKey(const ValueKey('auxiliary_floating_dock_tap')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('To-dos'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('floating_todo_input')),
      'Send the release note',
    );
    await tester.tap(find.byKey(const ValueKey('floating_todo_add')));
    await tester.pumpAndSettle();

    expect(find.text('Send the release note'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    // The generated item id is intentionally opaque; locate its semantic
    // action by the localized tooltip exposed by the row.
    await tester.tap(find.byTooltip('Send to main chat'));
    await tester.pumpAndSettle();
    expect(sent, ['Send the release note']);
    expect(find.byTooltip('Send to main chat'), findsNothing);
    expect(find.byTooltip('Submitted'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('floating_todo_input')),
      'Delete this task',
    );
    await tester.tap(find.byKey(const ValueKey('floating_todo_add')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this task'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete task').last);
    await tester.pumpAndSettle();
    expect(find.text('Delete this task'), findsNothing);

    await tester.pumpWidget(buildDock('durable-main', source: sourceB));
    await tester.pumpAndSettle();
    expect(find.text('Send the release note'), findsNothing);

    await tester.pumpWidget(buildDock('durable-main'));
    await tester.pumpAndSettle();
    expect(find.text('Send the release note'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    registry.dispose();
    await tester.pump();
  });

  testWidgets('collapsed badge includes active subagents for this parent', (
    tester,
  ) async {
    final bridge = _Bridge();
    final gateway = _Gateway()
      ..isConnected = true
      ..capabilities = {};
    final registry = EphemeralSideChatRegistryService(bridge: gateway);
    addTearDown(registry.dispose);
    addTearDown(gateway.dispose);
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuxiliaryFloatingDock(
            sessionId: 'parent-with-agent',
            bridgeService: bridge,
            registryService: registry,
            onOpenSideChat: (_, _, _) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    final request =
        jsonDecode(bridge.sent.last.toJson()) as Map<String, dynamic>;
    expect(request['type'], 'get_subagents');
    bridge.tagged.add((
      SubagentListMessage(
        sessionId: 'parent-with-agent',
        requestId: request['requestId'] as String,
        subagents: const [
          SubagentInfo(threadId: 'agent-running', status: 'running'),
          SubagentInfo(threadId: 'agent-done', status: 'done'),
        ],
      ),
      'parent-with-agent',
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('1'), findsOneWidget);

    bridge.tagged.add((
      SubagentActivitySummaryMessage(
        scope: 'runtime',
        ownerSessionId: 'parent-with-agent',
        providerThreadId: 'provider-parent',
        codexSourceId: 'source-1',
        revision: 'revision-1',
        activeCount: 1,
        totalCount: 2,
        truncated: false,
        subscribed: false,
        listRequestId: request['requestId'] as String,
      ),
      'parent-with-agent',
    ));
    await tester.pump();
    final watch = jsonDecode(bridge.sent.last.toJson()) as Map<String, dynamic>;
    expect(watch['type'], 'watch_subagent_activity_v1');
    bridge.tagged.add((
      SubagentActivitySummaryMessage(
        scope: 'runtime',
        ownerSessionId: 'parent-with-agent',
        providerThreadId: 'provider-parent',
        codexSourceId: 'source-1',
        revision: 'revision-2',
        activeCount: 2,
        totalCount: 2,
        truncated: false,
        subscribed: true,
        subscriptionId: watch['subscriptionId'] as String,
      ),
      'parent-with-agent',
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('2'), findsOneWidget);
  });

  testWidgets(
    'detached dock subagents use provider identity without sessionId',
    (tester) async {
      final bridge = _Bridge();
      final gateway = _Gateway()
        ..capabilities = {}
        ..isConnected = true;
      final registry = EphemeralSideChatRegistryService(bridge: gateway);
      addTearDown(registry.dispose);
      addTearDown(gateway.dispose);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AuxiliaryFloatingDock(
              sessionId: 'pane-1',
              parentProviderSessionId: 'provider-parent',
              detachedSubagentsProviderThreadId: 'provider-parent',
              detachedSubagentsCodexSourceId: 'source-1',
              bridgeService: bridge,
              registryService: registry,
              onOpenSideChat: (_, _, _) async {},
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('auxiliary_floating_dock_tap')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Subagents'));
      await tester.pumpAndSettle();

      final request =
          jsonDecode(bridge.sent.last.toJson()) as Map<String, dynamic>;
      expect(request['type'], 'get_detached_subagents');
      expect(request['ownerSessionId'], 'pane-1');
      expect(request['providerThreadId'], 'provider-parent');
      expect(request['codexSourceId'], 'source-1');
      expect(request.containsKey('sessionId'), isFalse);
    },
  );

  testWidgets(
    'filters detached and attached runtimes by the canonical provider parent',
    (tester) async {
      final bridge = _Bridge();
      final gateway = _Gateway();
      final registry = EphemeralSideChatRegistryService(bridge: gateway);
      gateway.isConnected = true;
      gateway.messagesController.add(
        EphemeralSideChatRegistryMessage(
          entries: [
            _entry(
              childSessionId: 'child-current',
              parentSessionId: 'runtime-parent',
              parentProviderSessionId: 'durable-thread',
            ),
            _entry(
              childSessionId: 'child-legacy',
              parentSessionId: 'runtime-parent',
            ),
            _entry(
              childSessionId: 'child-other',
              parentSessionId: 'runtime-other',
              parentProviderSessionId: 'durable-other',
            ),
          ],
        ),
      );
      addTearDown(registry.dispose);
      addTearDown(gateway.dispose);
      addTearDown(bridge.dispose);
      String? openedRuntimeParent;
      String? openedProviderParent;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AuxiliaryFloatingDock(
              sessionId: 'runtime-parent',
              parentProviderSessionId: 'durable-thread',
              bridgeService: bridge,
              registryService: registry,
              onOpenSideChat: (runtimeParent, providerParent, entry) async {
                openedRuntimeParent = runtimeParent;
                openedProviderParent = providerParent;
              },
            ),
          ),
        ),
      );

      expect(find.text('2'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('auxiliary_floating_dock_tap')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('auxiliary_side_chat_child-current')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('auxiliary_side_chat_child-legacy')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('auxiliary_side_chat_child-other')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('auxiliary_new_side_chat')));
      await tester.pump();
      expect(openedRuntimeParent, 'runtime-parent');
      expect(openedProviderParent, 'durable-thread');
    },
  );

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
              onOpenSideChat: (_, _, _) async {},
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
          onOpenSideChat: (_, _, _) async {},
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
          onOpenSideChat: (_, _, _) async {},
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

  testWidgets(
    'expanded panel does not block the conversation outside its bounds',
    (tester) async {
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
                    onOpenSideChat: (_, _, _) async {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('auxiliary_floating_dock_tap')),
      );
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
    },
  );
}
