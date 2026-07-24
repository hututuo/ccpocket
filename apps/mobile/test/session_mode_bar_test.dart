import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/session_mode_bar.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/claude_effort_motion_style.dart';
import 'package:ccpocket/widgets/codex_effort_motion.dart';
import 'package:ccpocket/widgets/codex_effort_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockBridgeService extends BridgeService {
  final _messageController = StreamController<ServerMessage>.broadcast();
  final _taggedController =
      StreamController<(ServerMessage, String?)>.broadcast();
  final _sessionListController =
      StreamController<List<SessionInfo>>.broadcast();
  final _modelCatalogController = StreamController<int>.broadcast();
  final _historySyncController = StreamController<String>.broadcast();
  final sentMessages = <ClientMessage>[];
  int _modelCatalogRevision = 0;
  List<String> availableCodexModels = const [];
  Map<String, List<String>> availableCodexReasoningEfforts = const {};
  Map<String, List<String>> availableCodexServiceTiers = const {};
  Set<String> advertisedBridgeCapabilities = const {
    ChatSessionCubit.codexPermissionApplyStrategyCapability,
  };
  bool runtimePermissionApplyStrategySupported = true;
  bool? runtimeNativePlanModeSupported;
  String? runtimeServiceTier;
  bool historySyncing = false;

  @override
  bool get isConnected => true;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection => true;

  @override
  List<String> get codexModels => availableCodexModels;

  @override
  Map<String, List<String>> get codexModelReasoningEfforts =>
      availableCodexReasoningEfforts;

  @override
  Map<String, List<String>> get codexModelServiceTiers =>
      availableCodexServiceTiers;

  @override
  int get codexModelCatalogRevision => _modelCatalogRevision;

  @override
  Stream<int> get codexModelCatalogChanges => _modelCatalogController.stream;

  @override
  Stream<String> get sessionHistorySyncChanges => _historySyncController.stream;

  @override
  bool isSessionHistorySyncing(String sessionId) => historySyncing;

  @override
  Set<String> get bridgeCapabilities => advertisedBridgeCapabilities;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionListController.stream;

  @override
  List<SessionInfo> get sessions => [
    SessionInfo(
      id: 'codex-session',
      provider: 'codex',
      projectPath: '/project',
      status: 'idle',
      createdAt: '',
      lastActivityAt: '',
      codexPermissionApplyStrategySupported:
          runtimePermissionApplyStrategySupported,
      codexNativePlanModeSupported: runtimeNativePlanModeSupported,
      codexServiceTier: runtimeServiceTier,
    ),
  ];

  void emitNativePlanModeSupport(bool? supported) {
    runtimeNativePlanModeSupported = supported;
    _sessionListController.add(sessions);
  }

  void emitServiceTier(String? serviceTier) {
    runtimeServiceTier = serviceTier;
    _sessionListController.add(sessions);
  }

  void emitModelCatalog() {
    _modelCatalogRevision++;
    _modelCatalogController.add(_modelCatalogRevision);
  }

  void emitHistorySync(bool syncing) {
    historySyncing = syncing;
    _historySyncController.add('codex-session');
  }

  void emitMessage(ServerMessage msg, {String? sessionId}) {
    _taggedController.add((msg, sessionId));
    _messageController.add(msg);
  }

  @override
  Stream<ServerMessage> get messages => _messageController.stream;

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) {
    return _taggedController.stream
        .where((pair) => pair.$2 == null || pair.$2 == sessionId)
        .map((pair) => pair.$1);
  }

  @override
  void send(ClientMessage message) {
    sentMessages.add(message);
  }

  @override
  void interrupt(String sessionId) {}

  @override
  void stopSession(String sessionId) {}

  @override
  void requestFileList(String projectPath) {}

  @override
  void requestSessionList() {}

  @override
  void requestSessionHistory(String sessionId) {}

  @override
  void dispose() {
    _messageController.close();
    _taggedController.close();
    _sessionListController.close();
    _modelCatalogController.close();
    _historySyncController.close();
    super.dispose();
  }
}

Future<void> _pumpWhileEffortIonsRun(
  WidgetTester tester, {
  Duration duration = const Duration(milliseconds: 400),
}) async {
  // Build state created by the interaction before advancing its animation.
  // pumpAndSettle is intentionally invalid while a high-tier ion ticker runs.
  await tester.pump();
  await tester.pump(duration);
}

Widget _wrap(
  ChatSessionCubit cubit, {
  bool showExtendedCodexEfforts = false,
  List<Widget> trailingWidgets = const [],
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: BlocProvider<ChatSessionCubit>.value(
        value: cubit,
        child: SessionModeBar(
          showExtendedCodexEfforts: showExtendedCodexEfforts,
          trailingWidgets: trailingWidgets,
        ),
      ),
    ),
  );
}

Map<String, dynamic> _decode(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

void main() {
  late _MockBridgeService bridge;
  late StreamingStateCubit streamingCubit;
  late ChatSessionCubit cubit;

  setUp(() async {
    bridge = _MockBridgeService();
    streamingCubit = StreamingStateCubit();
    cubit = ChatSessionCubit(
      sessionId: 'codex-session',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streamingCubit,
    );
    await Future<void>.microtask(() {});
  });

  tearDown(() async {
    await cubit.close();
    await streamingCubit.close();
    bridge.dispose();
  });

  testWidgets('mode bar accepts a compact local-feature slot', (tester) async {
    await tester.pumpWidget(
      _wrap(
        cubit,
        trailingWidgets: const [
          SizedBox(
            key: ValueKey('test_context_ring_slot'),
            width: 42,
            height: 28,
          ),
        ],
      ),
    );

    expect(
      find.byKey(const ValueKey('test_context_ring_slot')),
      findsOneWidget,
    );
    expect(find.byType(VerticalDivider), findsNWidgets(2));
  });

  testWidgets('empty local-feature slot leaves no orphan divider', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(cubit, trailingWidgets: const [SizedBox.shrink()]),
    );

    expect(find.byType(VerticalDivider), findsNWidgets(2));
  });

  testWidgets('mode bar glow tracks history sync instead of active Plan mode', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(cubit));

    bridge.emitMessage(
      const SystemMessage(
        subtype: 'set_permission_mode',
        permissionMode: 'plan',
      ),
      sessionId: 'codex-session',
    );
    bridge.emitMessage(
      const StatusMessage(status: ProcessStatus.running),
      sessionId: 'codex-session',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('session_history_sync_glow')),
      findsNothing,
    );

    bridge.emitHistorySync(true);
    await tester.pump();
    await tester.pump();
    expect(cubit.historySyncing.value, isTrue);
    expect(
      find.byKey(const ValueKey('session_history_sync_glow')),
      findsOneWidget,
    );

    bridge.emitHistorySync(false);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('session_history_sync_glow')),
      findsNothing,
    );
  });

  test('Codex Fast mode supports current and legacy metadata', () {
    expect(
      codexSupportsFast('gpt-5.6-sol', const {
        'gpt-5.6-sol': ['fast'],
      }),
      isTrue,
    );
    expect(
      codexSupportsFast('gpt-5.6-sol', const {
        'gpt-5.6-sol': ['priority'],
      }),
      isTrue,
    );
    expect(codexSupportsFast('gpt-5.5', const {}), isFalse);
    expect(codexSupportsFast('gpt-5.4-mini', const {}), isFalse);
  });

  test('Codex Effort slider caps at Extra High unless extended', () {
    const available = [
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
      ReasoningEffort.xhigh,
      ReasoningEffort.max,
      ReasoningEffort.ultra,
    ];

    expect(codexQuickEfforts(available).last, ReasoningEffort.xhigh);
    expect(codexQuickEfforts(available, current: ReasoningEffort.ultra), [
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
      ReasoningEffort.xhigh,
      ReasoningEffort.ultra,
    ]);
    expect(
      codexQuickEfforts(available, includeExtended: true),
      containsAllInOrder([ReasoningEffort.max, ReasoningEffort.ultra]),
    );
  });

  testWidgets('extended Codex Effort slider can select Ultra', (tester) async {
    bridge.availableCodexModels = const ['gpt-5.6-sol'];
    bridge.availableCodexReasoningEfforts = const {
      'gpt-5.6-sol': ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
    };

    await tester.pumpWidget(_wrap(cubit, showExtendedCodexEfforts: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('5.6 Sol high'));
    await tester.pumpAndSettle();

    final slider = find.byKey(const ValueKey('codex_effort_slider'));
    final sliderRect = tester.getRect(slider);
    await tester.tapAt(Offset(sliderRect.right - 8, sliderRect.center.dy));
    await _pumpWhileEffortIonsRun(
      tester,
      duration:
          ClaudeEffortMotionTokens.ultraRevealDuration +
          const Duration(milliseconds: 20),
    );

    expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
    expect(
      _decode(bridge.sentMessages.last),
      containsPair('modelReasoningEffort', 'ultra'),
    );
  });

  testWidgets('codex settings header fits narrow layouts with large text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(280, 600),
            textScaler: TextScaler.linear(3),
          ),
          child: Scaffold(
            body: SizedBox(
              width: 280,
              child: CodexSettingsPanel(
                model: 'gpt-a-very-long-future-model-name',
                effort: ReasoningEffort.fromValue(
                  'a-very-long-future-effort-name',
                ),
                speed: CodexSpeed.standard,
                supportsFast: false,
                onSpeedChanged: (_) {},
                speedButtonKey: 'speed',
                showAdvanced: false,
                advancedLabel: 'Advanced',
                toggleButtonKey: 'advanced',
                onToggleMode: () {},
                quickPanelKey: 'quick-panel',
                advancedPanelKey: 'advanced-panel',
                modelLabelKey: 'model-label',
                effortLabelKey: 'effort-label',
                quickChild: const SizedBox(height: 32),
                advancedChild: const SizedBox(height: 96),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('effort-label'))).overflow,
      TextOverflow.ellipsis,
    );
  });

  testWidgets('claude keeps permission and sandbox grouped', (tester) async {
    final claudeCubit = ChatSessionCubit(
      sessionId: 'claude-session',
      provider: Provider.claude,
      bridge: bridge,
      streamingCubit: streamingCubit,
    );
    addTearDown(claudeCubit.close);

    bridge.emitMessage(
      const SystemMessage(
        subtype: 'set_permission_mode',
        provider: 'claude',
        permissionMode: 'plan',
      ),
      sessionId: 'claude-session',
    );
    bridge.emitMessage(
      const StatusMessage(status: ProcessStatus.running),
      sessionId: 'claude-session',
    );

    await tester.pumpWidget(_wrap(claudeCubit));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Plan Off'), findsNothing);
    expect(find.text('Plan On'), findsNothing);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.byType(PermissionModeChip), findsOneWidget);
    expect(find.byKey(const ValueKey('plan_mode_chip_glow')), findsNothing);
  });

  testWidgets('claude auto permission mode is shown as Auto', (tester) async {
    final claudeCubit = ChatSessionCubit(
      sessionId: 'claude-auto-session',
      provider: Provider.claude,
      bridge: bridge,
      streamingCubit: streamingCubit,
      initialPermissionMode: PermissionMode.auto,
    );

    await tester.pumpWidget(_wrap(claudeCubit));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Auto'), findsOneWidget);
    expect(find.byIcon(Icons.auto_mode_outlined), findsOneWidget);

    await claudeCubit.close();
  });

  testWidgets('codex renders chips in Plan, Permissions order', (tester) async {
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    final plan = tester.getCenter(find.text('Plan Off')).dx;
    final permissions = tester.getCenter(find.text('On Request')).dx;

    expect(plan, lessThan(permissions));
    expect(find.text('Sandbox'), findsNothing);
  });

  testWidgets('codex model chip shows effective reasoning effort', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    expect(cubit.state.codexModelReasoningEffort, isNull);
    expect(find.text('5.5 high'), findsOneWidget);
  });

  testWidgets('open chat adopts a later Bridge model catalog', (tester) async {
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('5.5 high'), findsOneWidget);

    bridge.availableCodexModels = const ['gpt-5.5', 'gpt-5.7-sol'];
    bridge.availableCodexReasoningEfforts = const {
      'gpt-5.5': ['ultra'],
      'gpt-5.7-sol': ['medium', 'high', 'ultra'],
    };
    bridge.emitModelCatalog();
    await tester.pump();
    await tester.pump();
    expect(cubit.codexModelCatalogRevision.value, 1);

    // Keep the running session's current model, but immediately adopt the
    // newly advertised capabilities for that model.
    final updatedChip = tester.widget<CodexModelChip>(
      find.byType(CodexModelChip),
    );
    expect(updatedChip.model, 'gpt-5.5');
    expect(updatedChip.reasoningEffort?.value, 'ultra');
    expect(find.text('5.5 high'), findsNothing);
  });

  testWidgets('codex model menu supports GPT-5.6 max and ultra efforts', (
    tester,
  ) async {
    bridge.availableCodexModels = const ['gpt-5.6-sol'];
    bridge.availableCodexReasoningEfforts = const {
      'gpt-5.6-sol': ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
    };

    await tester.pumpWidget(_wrap(cubit, showExtendedCodexEfforts: true));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('5.6 Sol high'), findsOneWidget);
    await tester.tap(find.text('5.6 Sol high'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('codex_settings_model_label')),
          )
          .data,
      '5.6 Sol',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('codex_settings_effort_label')),
          )
          .data,
      'high',
    );
    expect(find.byKey(const ValueKey('codex_effort_slider')), findsOneWidget);
    final slider = tester.widget<CodexEffortMotionSlider>(
      find.byType(CodexEffortMotionSlider),
    );
    expect(slider.labels, [
      'light',
      'medium',
      'high',
      'x-high',
      'max',
      'ultra',
    ]);
    expect(slider.selectedIndex, 2);
    expect(slider.maxIndex, 4);
    expect(slider.ultraIndex, 5);
    final modeButton = find.byKey(const ValueKey('codex_settings_advanced'));
    expect(
      find.descendant(
        of: modeButton,
        matching: find.byIcon(Icons.tune_rounded),
      ),
      findsOneWidget,
    );
    final headerY = tester
        .getCenter(find.byKey(const ValueKey('codex_speed_button')))
        .dy;
    for (final key in const [
      'codex_settings_model_label',
      'codex_settings_effort_label',
      'codex_settings_advanced',
    ]) {
      expect(
        tester.getCenter(find.byKey(ValueKey(key))).dy,
        closeTo(headerY, 1),
      );
    }
    final modelBounds = tester.getRect(
      find.byKey(const ValueKey('codex_settings_model_label')),
    );
    final effortBounds = tester.getRect(
      find.byKey(const ValueKey('codex_settings_effort_label')),
    );
    expect(effortBounds.left - modelBounds.right, closeTo(8, 1));
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('codex_settings_effort_label')),
          )
          .style
          ?.fontWeight,
      FontWeight.w400,
    );

    slider.onSelected(5);
    await _pumpWhileEffortIonsRun(
      tester,
      duration:
          ClaudeEffortMotionTokens.ultraRevealDuration +
          const Duration(milliseconds: 20),
    );
    expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
    expect(
      _decode(bridge.sentMessages.last),
      containsPair('modelReasoningEffort', 'ultra'),
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('codex_settings_effort_label')),
          )
          .data,
      'ultra',
    );

    await tester.tap(find.byKey(const ValueKey('codex_settings_advanced')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: modeButton,
        matching: find.byIcon(Icons.linear_scale_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('codex_settings_quick_panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('codex_settings_advanced_panel')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('codex_effort_advanced')),
    );
    await tester.tap(find.byKey(const ValueKey('codex_effort_advanced')));
    await tester.pumpAndSettle();

    final ultraOption = find.byKey(
      const ValueKey('codex_effort_ultra_option'),
      skipOffstage: false,
    );
    expect(
      find.byKey(
        const ValueKey('codex_effort_max_option'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(ultraOption, findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('codex_effort_none_option'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    await tester.ensureVisible(ultraOption);
    await tester.pumpAndSettle();
    await tester.tap(ultraOption);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('codex_settings_advanced')));
    // Returning to the Ultra quick panel restarts its persistent ion ticker.
    await _pumpWhileEffortIonsRun(tester);
    expect(
      find.byKey(const ValueKey('codex_settings_quick_panel')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('codex_settings_effort_label')),
          )
          .data,
      'ultra',
    );
    expect(
      find.byKey(const ValueKey('codex_settings_advanced_panel')),
      findsNothing,
    );
  });

  testWidgets('codex speed toggles Fast for the next turn', (tester) async {
    bridge.availableCodexModels = const ['gpt-5.6-sol'];
    bridge.availableCodexReasoningEfforts = const {
      'gpt-5.6-sol': ['low', 'medium', 'high', 'xhigh', 'ultra'],
    };
    bridge.availableCodexServiceTiers = const {
      'gpt-5.6-sol': ['priority'],
    };

    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('5.6 Sol high'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex_speed_button')));
    await tester.pumpAndSettle();

    expect(cubit.state.codexSpeed, CodexSpeed.fast);
    expect(_decode(bridge.sentMessages.last), {
      'type': 'set_codex_speed',
      'serviceTier': 'fast',
      'sessionId': 'codex-session',
    });
  });

  testWidgets('codex advanced Speed picker includes Fast', (tester) async {
    bridge.availableCodexModels = const ['gpt-5.6-sol'];
    bridge.availableCodexReasoningEfforts = const {
      'gpt-5.6-sol': ['low', 'medium', 'high', 'xhigh'],
    };
    bridge.availableCodexServiceTiers = const {
      'gpt-5.6-sol': ['priority'],
    };

    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('5.6 Sol high'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex_settings_advanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex_speed_advanced')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('codex_speed_fast_option')),
      findsOneWidget,
    );
  });

  testWidgets('codex permissions sheet labels the active preset On Request', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('On Request'));
    await tester.pumpAndSettle();

    final activeTile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'On Request'),
    );
    expect(activeTile.trailing, isA<Icon>());
    expect((activeTile.trailing! as Icon).icon, Icons.check);
    expect(find.text('Default permissions'), findsNothing);
  });

  testWidgets('unknown runtime service tier stays visible and read-only', (
    tester,
  ) async {
    bridge.availableCodexModels = const ['gpt-5.6-sol'];
    bridge.availableCodexReasoningEfforts = const {
      'gpt-5.6-sol': ['low', 'medium', 'high', 'xhigh'],
    };
    bridge.availableCodexServiceTiers = const {
      'gpt-5.6-sol': ['fast'],
    };

    await tester.pumpWidget(_wrap(cubit));
    bridge.emitServiceTier('flex');
    await tester.pumpAndSettle();

    expect(cubit.state.codexSpeed, CodexSpeed.unknown);
    expect(cubit.codexServiceTierRaw.value, 'flex');
    expect(find.textContaining('flex'), findsOneWidget);

    await tester.tap(find.textContaining('flex'));
    await tester.pumpAndSettle();
    final speedButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('codex_speed_button')),
    );
    expect(speedButton.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('codex_settings_advanced')));
    await tester.pumpAndSettle();
    expect(find.text('flex (read-only)'), findsOneWidget);

    Navigator.of(tester.element(find.text('flex (read-only)'))).pop();
    await tester.pumpAndSettle();
    bridge.emitServiceTier(null);
    await tester.pumpAndSettle();
    expect(cubit.codexServiceTierRaw.value, isNull);
    expect(cubit.state.codexSpeed, CodexSpeed.standard);
    expect(find.textContaining('flex'), findsNothing);
  });

  testWidgets('codex model change prefers the first advertised Effort', (
    tester,
  ) async {
    bridge.availableCodexModels = const ['gpt-5.6-sol', 'gpt-5.4-mini'];
    bridge.availableCodexReasoningEfforts = const {
      'gpt-5.6-sol': ['xhigh', 'ultra'],
      'gpt-5.4-mini': ['low', 'medium'],
    };

    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('5.6 Sol x-high'));
    // The selected high tier intentionally keeps its pixel-ion ticker alive.
    // Pump only through the panel transition instead of waiting for quiescence.
    await _pumpWhileEffortIonsRun(tester);
    final advancedButton = find.byKey(
      const ValueKey('codex_settings_advanced'),
    );
    await tester.ensureVisible(advancedButton);
    await tester.pump();
    await tester.tap(advancedButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex_model_advanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5.4 Mini').last);
    await tester.pumpAndSettle();

    expect(
      _decode(bridge.sentMessages.last),
      containsPair('model', 'gpt-5.4-mini'),
    );
    expect(
      _decode(bridge.sentMessages.last),
      containsPair('modelReasoningEffort', 'low'),
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('codex_settings_effort_label')),
          )
          .data,
      'light',
    );
  });

  testWidgets('shows bar-level glow when running in plan mode', (tester) async {
    bridge.emitMessage(
      const SystemMessage(
        subtype: 'set_permission_mode',
        provider: 'codex',
        permissionMode: 'plan',
        executionMode: 'default',
        planMode: true,
      ),
      sessionId: 'codex-session',
    );
    bridge.emitMessage(
      const StatusMessage(status: ProcessStatus.running),
      sessionId: 'codex-session',
    );
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    // Chip-local glow is off; bar-level rotating glow is used instead
    expect(find.byKey(const ValueKey('plan_mode_chip_glow')), findsNothing);
  });

  testWidgets('plan toggle updates in place for idle codex session', (
    tester,
  ) async {
    bridge.emitMessage(
      const StatusMessage(status: ProcessStatus.idle),
      sessionId: 'codex-session',
    );
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Plan Off'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Enable Plan Mode'), findsNothing);
    expect(bridge.sentMessages, isNotEmpty);
    final message = _decode(bridge.sentMessages.last);
    expect(message['type'], 'set_permission_mode');
    expect(message['planMode'], true);
    expect(message['executionMode'], 'default');
  });

  testWidgets(
    'explicitly unsupported native Plan shows localized guidance without switching',
    (tester) async {
      bridge.emitNativePlanModeSupport(false);
      bridge.emitMessage(
        const StatusMessage(status: ProcessStatus.idle),
        sessionId: 'codex-session',
      );
      await tester.pumpWidget(_wrap(cubit));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Plan Off'));
      await tester.pump();

      expect(
        find.text(
          'This Codex runtime does not provide native Plan mode. '
          'Update Codex or reconnect to a compatible Bridge.',
        ),
        findsOneWidget,
      );
      expect(cubit.state.planMode, isFalse);
      expect(bridge.sentMessages, isEmpty);
    },
  );

  testWidgets(
    'codex permissions can apply from the next turn without restart',
    (tester) async {
      await tester.pumpWidget(_wrap(cubit));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('On Request'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.dragFrom(const Offset(400, 550), const Offset(0, -360));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Full access'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Apply permission change'), findsOneWidget);
      expect(find.text('From next turn'), findsOneWidget);
      expect(find.text('Restart now'), findsOneWidget);

      await tester.tap(find.text('From next turn'));
      await tester.pump(const Duration(milliseconds: 100));

      final message = _decode(bridge.sentMessages.last);
      expect(message['type'], 'set_permission_mode');
      expect(message['codexPermissionsMode'], 'fullAccess');
      expect(message['applyStrategy'], 'next_turn');

      final sentCount = bridge.sentMessages.length;
      await tester.tap(find.text('Plan Off'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(bridge.sentMessages, hasLength(sentCount));
    },
  );

  testWidgets('codex permissions retain explicit restart-now action', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('On Request'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(const Offset(400, 550), const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto-review'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Restart now'));
    await tester.pump(const Duration(milliseconds: 100));

    final message = _decode(bridge.sentMessages.last);
    expect(message['codexPermissionsMode'], 'autoReview');
    expect(message['applyStrategy'], 'restart_now');
  });

  testWidgets('unsupported Codex runtime uses the safe restart strategy', (
    tester,
  ) async {
    bridge.runtimePermissionApplyStrategySupported = false;
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('On Request'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(const Offset(400, 550), const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full access'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Change Approval Policy'), findsOneWidget);
    await tester.tap(find.text('Restart'));
    await tester.pump(const Duration(milliseconds: 100));

    final message = _decode(bridge.sentMessages.last);
    expect(message['applyStrategy'], 'restart_now');
    expect(message['permissionChangeId'], isA<String>());
  });

  testWidgets('old Bridge keeps the restart-only permission flow', (
    tester,
  ) async {
    bridge.advertisedBridgeCapabilities = const {};
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('On Request'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(const Offset(400, 550), const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full access'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Change Approval Policy'), findsOneWidget);
    expect(find.textContaining('will restart the session'), findsOneWidget);
    expect(find.text('From next turn'), findsNothing);

    await tester.tap(find.text('Restart'));
    await tester.pump(const Duration(milliseconds: 100));
    final message = _decode(bridge.sentMessages.last);
    expect(message.containsKey('applyStrategy'), isFalse);
  });

  testWidgets('codex mode bar does not render separate sandbox control', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(cubit));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Sandbox'), findsNothing);
    expect(find.text('On Request'), findsOneWidget);
  });
}
