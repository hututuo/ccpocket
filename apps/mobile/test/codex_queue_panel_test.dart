import 'package:ccpocket/features/codex_session/codex_session_screen.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  test('conversation queue parses additive staged delivery facts', () {
    final message =
        ServerMessage.fromJson({
              'type': 'conversation_queue',
              'sessionId': 's1',
              'limit': 1,
              'items': [
                {
                  'itemId': 'q1',
                  'text': 'Queued',
                  'createdAt': '2026-07-31T00:00:00.000Z',
                  'clientMessageId': 'cm1',
                  'deliveryStage': 'provider_accepted',
                },
              ],
            })
            as ConversationQueueMessage;

    expect(message.items.single.clientMessageId, 'cm1');
    expect(
      message.items.single.deliveryStage,
      QueuedInputDeliveryStage.providerAccepted,
    );
  });

  testWidgets('CodexQueuedInputPanel exposes steer edit and cancel actions', (
    tester,
  ) async {
    var steered = false;
    var edited = false;
    var canceled = false;

    await tester.pumpWidget(
      _wrap(
        CodexQueuedInputPanel(
          item: const QueuedInputItem(
            itemId: 'q1',
            text: 'Follow up after this turn',
            createdAt: '2026-04-25T00:00:00.000Z',
          ),
          onSteer: () => steered = true,
          onEdit: () => edited = true,
          onCancel: () => canceled = true,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('codex_queue_panel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex_queue_steer_button')),
      findsOneWidget,
    );
    expect(find.text('Follow up after this turn'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex_queue_steer_button')));
    expect(steered, isTrue);

    await tester.tap(find.byKey(const ValueKey('codex_queue_edit_button')));
    expect(edited, isTrue);

    await tester.tap(find.byKey(const ValueKey('codex_queue_cancel_button')));
    expect(canceled, isTrue);
  });

  testWidgets('CodexQueuedInputPanel shows reconnect copy for offline queue', (
    tester,
  ) async {
    var edited = false;
    var canceled = false;

    await tester.pumpWidget(
      _wrap(
        CodexQueuedInputPanel(
          item: const QueuedInputItem(
            itemId: 'offline:cm1',
            text: 'Offline pending message',
            createdAt: '2026-04-25T00:00:00.000Z',
          ),
          isOfflinePending: true,
          onSteer: null,
          onEdit: () => edited = true,
          onCancel: () => canceled = true,
        ),
      ),
    );

    expect(find.text('Queued for reconnect'), findsOneWidget);
    final steerButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('codex_queue_steer_button')),
    );
    expect(steerButton.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('codex_queue_edit_button')));
    expect(edited, isTrue);

    await tester.tap(find.byKey(const ValueKey('codex_queue_cancel_button')));
    expect(canceled, isTrue);
  });

  testWidgets('CodexQueuedInputPanel hides steer for delivery pending', (
    tester,
  ) async {
    var edited = false;
    var canceled = false;

    await tester.pumpWidget(
      _wrap(
        CodexQueuedInputPanel(
          item: const QueuedInputItem(
            itemId: 'pending:cm1',
            text: 'Slow delivery message',
            createdAt: '2026-04-25T00:00:00.000Z',
          ),
          isDeliveryPending: true,
          onSteer: null,
          onEdit: () => edited = true,
          onCancel: () => canceled = true,
        ),
      ),
    );

    expect(find.text('Pending delivery'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex_queue_steer_button')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('codex_queue_edit_button')));
    expect(edited, isTrue);

    await tester.tap(find.byKey(const ValueKey('codex_queue_cancel_button')));
    expect(canceled, isTrue);
  });

  testWidgets('CodexQueuedInputPanel shows one then two delivery checks', (
    tester,
  ) async {
    const bridgeAccepted = QueuedInputItem(
      itemId: 'q1',
      text: 'Follow up',
      createdAt: '2026-07-31T00:00:00.000Z',
      clientMessageId: 'cm1',
      deliveryStage: QueuedInputDeliveryStage.bridgeAccepted,
    );
    await tester.pumpWidget(
      _wrap(
        const CodexQueuedInputPanel(
          item: bridgeAccepted,
          onSteer: null,
          onEdit: null,
          onCancel: null,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('codex_queue_bridge_accepted')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('codex_queue_provider_accepted')),
      findsNothing,
    );

    await tester.pumpWidget(
      _wrap(
        CodexQueuedInputPanel(
          item: bridgeAccepted.withDeliveryStage(
            QueuedInputDeliveryStage.providerAccepted,
          ),
          onSteer: null,
          onEdit: null,
          onCancel: null,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('codex_queue_bridge_accepted')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('codex_queue_provider_accepted')),
      findsOneWidget,
    );
  });

  testWidgets('CodexQueuedInputPanel exposes provider rejection without '
      'claiming delivery', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const CodexQueuedInputPanel(
          item: QueuedInputItem(
            itemId: 'q1',
            text: 'Follow up',
            createdAt: '2026-07-31T00:00:00.000Z',
            clientMessageId: 'cm1',
            deliveryStage: QueuedInputDeliveryStage.providerRejected,
            deliveryError: 'provider unavailable',
          ),
          onSteer: null,
          onEdit: null,
          onCancel: null,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('codex_queue_provider_rejected')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('codex_queue_provider_accepted')),
      findsNothing,
    );
    expect(find.text('provider unavailable'), findsOneWidget);
  });

  test('moveQueuedInputToComposer cancels queue and overwrites input text', () {
    var canceled = false;
    final controller = TextEditingController(text: 'existing draft');
    addTearDown(controller.dispose);

    moveQueuedInputToComposer(
      inputController: controller,
      item: const QueuedInputItem(
        itemId: 'q1',
        text: 'Queued replacement',
        createdAt: '2026-04-25T00:00:00.000Z',
      ),
      cancelQueuedInput: () => canceled = true,
    );

    expect(canceled, isTrue);
    expect(controller.text, 'Queued replacement');
    expect(controller.selection.baseOffset, 'Queued replacement'.length);
  });
}
