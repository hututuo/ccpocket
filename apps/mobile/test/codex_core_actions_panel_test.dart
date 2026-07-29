import 'dart:async';

import 'package:ccpocket/features/codex_core_actions/codex_core_actions_panel.dart';
import 'package:ccpocket/features/codex_core_actions/codex_core_actions_strings.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends BridgeService {
  final local = StreamController<LocalFeatureServerMessage>.broadcast();
  final connections = StreamController<BridgeConnectionState>.broadcast();

  @override
  bool get isConnected => false;

  @override
  Stream<BridgeConnectionState> get connectionStatus => connections.stream;

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) => local.stream.where((message) => message.sessionId == sessionId);

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
}
