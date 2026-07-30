import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/auto_approval/auto_approval_global_control.dart';
import 'package:ccpocket/features/auto_approval/auto_approval_panel.dart';
import 'package:ccpocket/features/auto_approval/auto_approval_service.dart';
import 'package:ccpocket/features/auto_approval/auto_approval_ui_slot.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature_host.dart';
import 'package:ccpocket/models/messages.dart' hide Provider;
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final _sessionsController = StreamController<List<SessionInfo>>.broadcast();
  final _featureController =
      StreamController<LocalFeatureServerMessage>.broadcast();
  final sent = <ClientMessage>[];
  bool connected = true;
  bool autoApprovalEnabled = false;
  bool externalAppServer = false;
  List<SessionInfo> currentSessions = const [
    SessionInfo(
      id: 'session-1',
      provider: 'codex',
      projectPath: '/tmp/project',
      claudeSessionId: 'thread-1',
      status: 'running',
      createdAt: '',
      lastActivityAt: '',
    ),
  ];

  @override
  bool get isConnected => connected;

  @override
  String? get lastUrl => 'wss://bridge.example.test:8765/ws';

  @override
  List<SessionInfo> get sessions => currentSessions;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionsController.stream;

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      _featureController.stream;

  @override
  void send(ClientMessage message) {
    sent.add(message);
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    scheduleMicrotask(() {
      switch (json['type']) {
        case 'get_auto_approval_state':
          _featureController.add(
            AutoApprovalStateMessage(
              sessionId: json['sessionId'] as String,
              requestId: json['requestId'] as String,
              providerSessionId: externalAppServer ? null : 'thread-1',
              enabled: externalAppServer ? null : autoApprovalEnabled,
              enabledConversationCount: autoApprovalEnabled ? 1 : 0,
              approvedCount: 0,
              supervisionAvailable: !externalAppServer,
              unavailableReason: externalAppServer
                  ? 'external_app_server'
                  : null,
              reason: 'query',
              error: externalAppServer ? 'independent server' : null,
              errorCode: externalAppServer
                  ? 'external_app_server_approval_unsupported'
                  : null,
            ),
          );
        case 'set_auto_approval':
          autoApprovalEnabled = json['enabled'] as bool;
          _featureController.add(
            AutoApprovalStateMessage(
              sessionId: json['sessionId'] as String,
              requestId: json['requestId'] as String,
              providerSessionId: 'thread-1',
              enabled: autoApprovalEnabled,
              enabledConversationCount: autoApprovalEnabled ? 1 : 0,
              approvedCount: 0,
              reason: 'updated',
            ),
          );
        case 'import_legacy_auto_approvals':
          autoApprovalEnabled = (json['providerSessionIds'] as List).isNotEmpty;
          _featureController.add(
            AutoApprovalStateMessage(
              sessionId: json['sessionId'] as String,
              requestId: json['requestId'] as String,
              enabledConversationCount: autoApprovalEnabled ? 1 : 0,
              reason: 'legacy_imported',
            ),
          );
        case 'disable_all_auto_approvals':
          autoApprovalEnabled = false;
          _featureController.add(
            AutoApprovalStateMessage(
              sessionId: json['sessionId'] as String,
              requestId: json['requestId'] as String,
              enabledConversationCount: 0,
              reason: 'disabled_all',
            ),
          );
      }
    });
  }

  @override
  void dispose() {
    _sessionsController.close();
    _featureController.close();
    super.dispose();
  }
}

Future<
  ({
    _Bridge bridge,
    AutoApprovalService service,
    DraftService drafts,
    SharedPreferences preferences,
  })
>
_services({
  Map<String, Object> initialPreferences = const {},
  bool externalAppServer = false,
}) async {
  SharedPreferences.setMockInitialValues(initialPreferences);
  final preferences = await SharedPreferences.getInstance();
  final bridge = _Bridge();
  bridge.externalAppServer = externalAppServer;
  final service = AutoApprovalService(bridge: bridge, preferences: preferences)
    ..initialize();
  return (
    bridge: bridge,
    service: service,
    drafts: DraftService(preferences),
    preferences: preferences,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('panel toggles supervision and exposes its explicit boundary', (
    tester,
  ) async {
    final services = await _services();
    addTearDown(services.service.dispose);
    addTearDown(services.bridge.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AutoApprovalService>.value(
        value: services.service,
        child: const MaterialApp(
          home: Scaffold(body: AutoApprovalPanel(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Auto-approve this conversation'), findsOneWidget);
    expect(
      find.textContaining('plugin or connector installation'),
      findsOneWidget,
    );
    expect(find.textContaining('immediately starts executing'), findsOneWidget);
    expect(services.service.isEnabledForSession('session-1'), isFalse);

    await tester.tap(find.byKey(const ValueKey('auto_approval_switch')));
    await tester.pumpAndSettle();

    expect(services.service.isEnabledForSession('session-1'), isTrue);
    expect(find.text('Scope and risk'), findsOneWidget);
  });

  testWidgets('panel explains independent Desktop app-server boundary', (
    tester,
  ) async {
    final services = await _services(externalAppServer: true);
    addTearDown(services.service.dispose);
    addTearDown(services.bridge.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AutoApprovalService>.value(
        value: services.service,
        child: const MaterialApp(
          home: Scaffold(body: AutoApprovalPanel(sessionId: 'session-1')),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('independent Codex app-server'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('auto_approval_switch')),
    );
    expect(toggle.onChanged, isNull);
  });

  testWidgets('host registers an isolated menu, status, and pane slot', (
    tester,
  ) async {
    final services = await _services();
    addTearDown(services.service.dispose);
    addTearDown(services.bridge.dispose);
    final input = TextEditingController();
    addTearDown(input.dispose);
    late CodexSessionFeatureContext featureContext;
    final opened = <String>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AutoApprovalService>.value(
            value: services.service,
          ),
          Provider<DraftService>.value(value: services.drafts),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              featureContext = CodexSessionFeatureContext(
                context: context,
                sessionId: 'session-1',
                bridge: services.bridge,
                inputController: input,
                draftService: services.drafts,
                requestCompact: () {},
                openPane: (featureId, {arguments = const {}}) async {
                  opened.add(featureId);
                },
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    final action = LocalSessionFeatureHost.overflowActions(
      featureContext,
    ).singleWhere((candidate) => candidate.featureId == 'auto_approval');
    expect(action.label, 'Auto approval');
    expect(action.order, 35);

    final descriptor = LocalSessionFeatureHost.paneDescriptor('auto_approval');
    expect(descriptor, isNotNull);
    expect(descriptor!.rememberPerSession, isFalse);
    expect(
      descriptor.builder(
        WorkspaceFeaturePaneContext(
          context: featureContext.context,
          sessionId: 'session-1',
          bridge: services.bridge,
          onClose: () {},
        ),
      ),
      isA<AutoApprovalPanel>(),
    );

    await services.service.setEnabledForSession('session-1', true);
    await tester.pump();
    final statusWidget = LocalSessionFeatureHost.statusWidgets(featureContext)
        .singleWhere(
          (widget) => widget.key == const ValueKey('auto_approval_status_slot'),
        );
    await tester.pumpWidget(
      ChangeNotifierProvider<AutoApprovalService>.value(
        value: services.service,
        child: MaterialApp(home: Scaffold(body: statusWidget)),
      ),
    );
    expect(
      find.byKey(const ValueKey('auto_approval_status_chip')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('auto_approval_status_chip')));
    expect(opened, ['auto_approval']);
  });

  testWidgets('settings can queue Bridge supervision shutdown while offline', (
    tester,
  ) async {
    final identity = jsonEncode([
      1,
      'endpoint:wss://bridge.example.test:8765/ws',
      'codex',
      'thread-1',
    ]);
    final services = await _services(
      initialPreferences: {
        AutoApprovalService.preferencesKey: [identity],
      },
    );
    addTearDown(services.service.dispose);
    addTearDown(services.bridge.dispose);
    services.bridge
      ..connected = false
      ..currentSessions = const [];

    await tester.pumpWidget(
      ChangeNotifierProvider<AutoApprovalService>.value(
        value: services.service,
        child: const MaterialApp(
          home: Scaffold(body: AutoApprovalGlobalControl()),
        ),
      ),
    );

    expect(services.service.hasEnabledConversations, isTrue);
    await tester.tap(find.byKey(const ValueKey('auto_approval_disable_all')));
    await tester.pumpAndSettle();

    expect(services.service.hasEnabledConversations, isFalse);
    expect(
      services.preferences.getStringList(AutoApprovalService.preferencesKey),
      isEmpty,
    );
    expect(find.textContaining('emergency stop is queued'), findsOneWidget);
  });

  testWidgets('feature UI stays absent when its provider is not installed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final bridge = _Bridge();
    final drafts = DraftService(preferences);
    final input = TextEditingController();
    addTearDown(bridge.dispose);
    addTearDown(input.dispose);
    late CodexSessionFeatureContext featureContext;

    await tester.pumpWidget(
      Provider<DraftService>.value(
        value: drafts,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              featureContext = CodexSessionFeatureContext(
                context: context,
                sessionId: 'session-1',
                bridge: bridge,
                inputController: input,
                draftService: drafts,
                requestCompact: () {},
                openPane: (featureId, {arguments = const {}}) async {},
              );
              return const Scaffold(
                body: Column(
                  children: [
                    AutoApprovalGlobalControl(),
                    AutoApprovalPanel(sessionId: 'session-1'),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(autoApprovalUiSlot.overflowActions(featureContext), isEmpty);
    expect(autoApprovalUiSlot.statusWidgets(featureContext), isEmpty);
    expect(find.byKey(const ValueKey('auto_approval_switch')), findsNothing);
  });
}
