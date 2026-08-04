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
              'limit': 16,
              'items': [
                {
                  'itemId': 'q1',
                  'text': 'Queued',
                  'createdAt': '2026-07-31T00:00:00.000Z',
                  'clientMessageId': 'cm1',
                  'deliveryStage': 'provider_accepted',
                },
                {
                  'itemId': 'q2',
                  'text': 'Queued second',
                  'createdAt': '2026-07-31T00:00:01.000Z',
                  'clientMessageId': 'cm2',
                  'deliveryStage': 'bridge_accepted',
                },
              ],
            })
            as ConversationQueueMessage;

    expect(message.limit, 16);
    expect(message.items, hasLength(2));
    expect(message.items.first.clientMessageId, 'cm1');
    expect(
      message.items.first.deliveryStage,
      QueuedInputDeliveryStage.providerAccepted,
    );
  });

  test(
    'session summaries preserve the additive full queue and legacy head',
    () {
      final session = SessionInfo.fromJson({
        'id': 'runtime-1',
        'provider': 'codex',
        'projectPath': '/tmp/project',
        'status': 'running',
        'queuedInputLimit': 16,
        'queuedInput': {
          'itemId': 'q1',
          'text': 'first',
          'createdAt': '2026-08-04T00:00:00.000Z',
        },
        'queuedInputs': [
          {
            'itemId': 'q1',
            'text': 'first',
            'createdAt': '2026-08-04T00:00:00.000Z',
          },
          {
            'itemId': 'q2',
            'text': 'second',
            'createdAt': '2026-08-04T00:00:01.000Z',
          },
        ],
      });

      expect(session.queuedInputLimit, 16);
      expect(session.queuedInput?.itemId, 'q1');
      expect(session.queuedInputs.map((item) => item.itemId), ['q1', 'q2']);
    },
  );

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

  testWidgets(
    'CodexQueuedInputPanel has no fake controls for delivery pending',
    (tester) async {
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

      expect(
        find.byKey(const ValueKey('codex_queue_edit_button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('codex_queue_cancel_button')),
        findsNothing,
      );
      expect(edited, isFalse);
      expect(canceled, isFalse);
    },
  );

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

  test(
    'moveQueuedInputToComposer cancels queue and overwrites input text',
    () async {
      var canceled = false;
      final controller = TextEditingController(text: 'existing draft');
      addTearDown(controller.dispose);

      expect(
        await moveQueuedInputToComposer(
          inputController: controller,
          item: const QueuedInputItem(
            itemId: 'q1',
            text: 'Queued replacement',
            createdAt: '2026-04-25T00:00:00.000Z',
          ),
          cancelQueuedInput: () async {
            canceled = true;
            return true;
          },
        ),
        isTrue,
      );

      expect(canceled, isTrue);
      expect(controller.text, 'Queued replacement');
      expect(controller.selection.baseOffset, 'Queued replacement'.length);
    },
  );

  test(
    'moveQueuedInputToComposer keeps draft when cancellation loses race',
    () async {
      final controller = TextEditingController(text: 'existing draft');
      addTearDown(controller.dispose);

      expect(
        await moveQueuedInputToComposer(
          inputController: controller,
          item: const QueuedInputItem(
            itemId: 'offline:cm1',
            text: 'Queued replacement',
            createdAt: '2026-04-25T00:00:00.000Z',
          ),
          cancelQueuedInput: () async => false,
        ),
        isFalse,
      );
      expect(controller.text, 'existing draft');
    },
  );
}
