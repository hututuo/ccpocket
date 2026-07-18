import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_archive/session_archive_cubit.dart';
import 'package:ccpocket/features/session_archive/session_archive_screen.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _WidgetArchiveBridge extends BridgeService {
  final messagesController = StreamController<ServerMessage>.broadcast();
  final connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final sent = <ClientMessage>[];

  @override
  Set<String> get bridgeCapabilities => const {codexSessionLifecycleCapability};

  @override
  Stream<ServerMessage> get messages => messagesController.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      connectionController.stream;

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  void dispose() {
    messagesController.close();
    connectionController.close();
  }
}

void main() {
  testWidgets('permanent delete stays disabled until DELETE is typed', (
    tester,
  ) async {
    final bridge = _WidgetArchiveBridge();
    final ids = ['list-1', 'delete-1'].iterator;
    String nextId() {
      ids.moveNext();
      return ids.current;
    }

    final cubit = SessionArchiveCubit(bridge: bridge, createRequestId: nextId);
    addTearDown(() async {
      await cubit.close();
      bridge.dispose();
    });
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SessionArchiveScreen(),
        ),
      ),
    );
    bridge.messagesController.add(
      const ArchivedSessionsResultMessage(
        requestId: 'list-1',
        success: true,
        sessions: [
          ArchivedSessionRecord(
            sessionId: 'thread-1',
            provider: 'codex',
            projectPath: '/project',
            archivedAt: '2026-07-18T00:00:00Z',
            name: 'Archived thread',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived thread'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('archived_session_actions_codex_thread-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();

    final confirm = find.byKey(
      const ValueKey('confirm_permanent_delete_button'),
    );
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('permanent_delete_confirmation_input')),
      'delete',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('permanent_delete_confirmation_input')),
      'DELETE',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pump();

    final sent = jsonDecode(bridge.sent.last.toJson()) as Map<String, dynamic>;
    expect(sent['type'], 'delete_session');
    expect(sent['confirmDescendantDeletion'], isTrue);
    bridge.messagesController.add(
      const SessionLifecycleResultMessage(
        type: 'delete_session_result',
        requestId: 'delete-1',
        sessionId: 'thread-1',
        success: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived thread'), findsNothing);
    expect(find.textContaining('spawned descendants deleted'), findsOneWidget);
  });

  testWidgets('Claude archive actions never expose permanent deletion', (
    tester,
  ) async {
    final bridge = _WidgetArchiveBridge();
    final cubit = SessionArchiveCubit(
      bridge: bridge,
      createRequestId: () => 'list-1',
    );
    addTearDown(() async {
      await cubit.close();
      bridge.dispose();
    });
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SessionArchiveScreen(),
        ),
      ),
    );
    bridge.messagesController.add(
      const ArchivedSessionsResultMessage(
        requestId: 'list-1',
        success: true,
        sessions: [
          ArchivedSessionRecord(
            sessionId: 'claude-1',
            provider: 'claude',
            projectPath: '/project',
            archivedAt: '2026-07-18T00:00:00Z',
            name: 'Claude archive',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('archived_session_actions_claude_claude-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Restore'), findsOneWidget);
    expect(find.text('Delete permanently'), findsNothing);
  });
}
