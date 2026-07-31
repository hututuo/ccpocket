import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/codex_core_actions/codex_core_actions_panel.dart';
import 'package:ccpocket/features/codex_core_actions/codex_core_actions_strings.dart';
import 'package:ccpocket/features/codex_core_actions/codex_core_actions_ui_slot.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final local = StreamController<LocalFeatureServerMessage>.broadcast();
  final connections = StreamController<BridgeConnectionState>.broadcast();
  final sent = <ClientMessage>[];
  bool connected = false;

  @override
  bool get isConnected => connected;

  @override
  Stream<BridgeConnectionState> get connectionStatus => connections.stream;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => local.stream.where((message) => message.sessionId == sessionId);

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  void dispose() {
    local.close();
    connections.close();
    super.dispose();
  }
}

void main() {
  testWidgets('Codex tools pane no longer contains a Compact page', (
    tester,
  ) async {
    final bridge = _Bridge();
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CodexCoreActionsPanel(
            sessionId: 'session-1',
            bridge: bridge,
            initialSection: 'compact',
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('codex_core_compact_card')), findsNothing);
    expect(
      find.byKey(const ValueKey('codex_core_compact_button')),
      findsNothing,
    );
    expect(find.text('Code review'), findsOneWidget);
  });

  testWidgets('known compact failures stay localized without raw details', (
    tester,
  ) async {
    late String feedback;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            feedback = codexCoreActionErrorText(
              CodexCoreActionsStrings.of(context),
              'request_timeout',
              'Request timed out',
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(feedback, '请求超时，请稍后重试。');
  });

  testWidgets(
    'durable core actions pane follows runtime revisions and fails closed',
    (tester) async {
      final bridge = _Bridge()..connected = true;
      final revision = ValueNotifier<int>(0);
      String? currentRuntimeSessionId = 'runtime-old';
      addTearDown(revision.dispose);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: codexCoreActionsUiSlot.paneDescriptor!.builder(
                WorkspaceFeaturePaneContext(
                  context: context,
                  sessionId: 'durable-thread',
                  bridge: bridge,
                  arguments: {
                    'durableRoute': true,
                    'runtimeSessionId': 'runtime-old',
                    'runtimeSessionIdResolver': () => currentRuntimeSessionId,
                    'runtimeRevisionListenable': revision,
                  },
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('codex_review_start')));
      await tester.pump();
      expect(
        (jsonDecode(bridge.sent.single.toJson())
            as Map<String, dynamic>)['sessionId'],
        'runtime-old',
      );

      bridge.sent.clear();
      currentRuntimeSessionId = 'runtime-new';
      revision.value += 1;
      await tester.pump();
      expect(find.byType(CodexCoreActionsPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('codex_review_start')));
      await tester.pump();
      expect(
        (jsonDecode(bridge.sent.single.toJson())
            as Map<String, dynamic>)['sessionId'],
        'runtime-new',
      );

      bridge.sent.clear();
      currentRuntimeSessionId = null;
      revision.value += 1;
      await tester.pump();
      expect(find.byType(CodexCoreActionsPanel), findsNothing);
      expect(bridge.sent, isEmpty);
    },
  );
}
