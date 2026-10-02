import 'dart:async';
import 'dart:io';

import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'conversation_content_sync_service_test.dart'
    show FakeConversationContentGateway;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final v2 in [true, false]) {
    group(v2 ? 'V2 subscription focus' : 'V1 subscription focus', () {
      late Directory directory;
      late SessionCatalogCacheRepository repository;
      late FakeConversationContentGateway gateway;
      late ConversationContentSyncService service;
      Completer<void>? databaseOpenGate;
      final subscribeType = v2
          ? 'conversation_sync_subscribe'
          : 'conversation_content_subscribe';
      final focusType = v2
          ? 'conversation_sync_focus'
          : 'conversation_content_focus';

      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'ccpocket_subscription_focus_',
        );
        databaseOpenGate = null;
        repository = SessionCatalogCacheRepository(
          SessionCatalogCacheDatabase(
            databasePath: path.join(directory.path, 'cache.db'),
            openDatabase: (databasePath, options) async {
              await databaseOpenGate?.future;
              return databaseFactoryFfi.openDatabase(
                databasePath,
                options: options,
              );
            },
          ),
        );
        gateway = FakeConversationContentGateway()
          ..supportsConversationSyncV2 = v2;
        service = ConversationContentSyncService(
          bridge: gateway,
          cache: repository,
        );
      });

      tearDown(() async {
        if (databaseOpenGate?.isCompleted == false) {
          databaseOpenGate!.complete();
        }
        await service.dispose();
        await repository.close();
        await gateway.close();
        await directory.delete(recursive: true);
      });

      void focus(String? thread) {
        service.setFocusedConversation(
          provider: thread == null ? null : 'codex',
          providerSessionId: thread,
        );
      }

      List<Map<String, dynamic>> focusFrames() =>
          gateway.sent.where((frame) => frame['type'] == focusType).toList();

      Map<String, String> target(String thread) => {
        'provider': 'codex',
        'providerSessionId': thread,
      };

      Future<Map<String, dynamic>> start({String? initialFocus}) async {
        if (initialFocus != null) focus(initialFocus);
        service.start(initialLifecycleState: AppLifecycleState.resumed);
        return gateway.nextOutgoing(subscribeType);
      }

      void begin(String subscriptionId, {String source = 'codex-home-a'}) {
        gateway.addEvent(
          v2
              ? ConversationSyncV2EventMessage(
                  event: ConversationSyncV2EventKind.syncBegin,
                  subscriptionId: subscriptionId,
                  bridgeInstanceId: 'bridge-1',
                  codexSourceId: source,
                  batchId: 'batch-$subscriptionId',
                  sequence: 1,
                  requestId: subscriptionId,
                )
              : ConversationContentEventMessage(
                  event: ConversationContentEventKind.subscribed,
                  subscriptionId: subscriptionId,
                  bridgeInstanceId: 'bridge-1',
                  requestId: subscriptionId,
                  hotConversationLimit: 10,
                ),
        );
      }

      Future<void> accept(String subscriptionId) async {
        begin(subscriptionId);
        if (v2) await gateway.nextOutgoing('conversation_sync_ack');
        await pumpEventQueue();
      }

      test(
        'replays the latest focus changed after subscribe was sent',
        () async {
          final subscribe = await start();
          expect(subscribe['focused'], isNull);
          final id = subscribe['requestId']! as String;
          focus('thread-a');
          focus('thread-b');
          expect(focusFrames(), isEmpty);

          await accept(id);

          expect(focusFrames(), hasLength(1));
          expect(focusFrames().single['subscriptionId'], id);
          expect(focusFrames().single['focused'], target('thread-b'));
          expect(
            gateway.sentTypes.where((type) => type == subscribeType),
            hasLength(1),
          );
        },
      );

      test('replays a focus cleared while subscribe is pending', () async {
        final subscribe = await start(initialFocus: 'thread-a');
        expect(subscribe['focused'], target('thread-a'));
        focus(null);

        await accept(subscribe['requestId']! as String);

        expect(focusFrames(), hasLength(1));
        expect(focusFrames().single['focused'], isNull);
      });

      test(
        'does not resend when the focus returns to its sent value',
        () async {
          final subscribe = await start(initialFocus: 'thread-a');
          focus('thread-b');
          focus('thread-a');

          await accept(subscribe['requestId']! as String);

          expect(focusFrames(), isEmpty);
        },
      );

      test(
        'keeps unchanged bootstrap and ordinary active focus behavior',
        () async {
          final subscribe = await start(initialFocus: 'thread-a');
          final id = subscribe['requestId']! as String;
          await accept(id);
          expect(focusFrames(), isEmpty);

          focus('thread-b');
          focus('thread-b');

          expect(focusFrames(), hasLength(1));
          expect(focusFrames().single['subscriptionId'], id);
          expect(focusFrames().single['focused'], target('thread-b'));
        },
      );

      test('old acceptance cannot consume the replacement focus', () async {
        final first = await start();
        final firstId = first['requestId']! as String;
        focus('thread-a');
        expect(service.retryBootstrap(), isTrue);
        final replacement = await gateway.nextOutgoing(subscribeType);
        final replacementId = replacement['requestId']! as String;
        expect(replacementId, isNot(firstId));
        expect(replacement['focused'], target('thread-a'));
        focus('thread-b');

        begin(firstId);
        await pumpEventQueue();
        expect(focusFrames(), isEmpty);
        await accept(replacementId);

        expect(focusFrames(), hasLength(1));
        expect(focusFrames().single['subscriptionId'], replacementId);
        expect(focusFrames().single['focused'], target('thread-b'));
      });

      test(
        'dispose retires pending focus without sending from late acceptance',
        () async {
          final subscribe = await start();
          focus('thread-a');
          await service.dispose();
          final sentCount = gateway.sent.length;

          begin(subscribe['requestId']! as String);
          await pumpEventQueue();

          expect(focusFrames(), isEmpty);
          expect(gateway.sent, hasLength(sentCount));
        },
      );

      test('failed catch-up send retires the accepted transport', () async {
        final subscribe = await start();
        focus('thread-a');
        gateway.throwOnClientType = focusType;

        begin(subscribe['requestId']! as String);
        await pumpEventQueue();

        final diagnostics = service.diagnosticSnapshot(
          provider: 'codex',
          providerSessionId: 'thread-a',
        );
        expect(diagnostics['activeSubscriptionId'], isNull);
        expect(diagnostics['pendingSubscriptionId'], isNull);
        expect(focusFrames(), isEmpty);
        if (v2)
          expect(gateway.sentTypes, isNot(contains('conversation_sync_ack')));
      });

      if (v2) {
        test(
          'rejected source cannot consume pending focus reconciliation',
          () async {
            final subscribe = await start();
            final id = subscribe['requestId']! as String;
            focus('thread-a');

            begin(id, source: 'codex-home-obsolete');
            await pumpEventQueue();
            expect(focusFrames(), isEmpty);
            await accept(id);

            expect(focusFrames(), hasLength(1));
            expect(focusFrames().single['focused'], target('thread-a'));
          },
        );

        test(
          'focus changed before wire send is already carried by subscribe',
          () async {
            databaseOpenGate = Completer<void>();
            focus('thread-a');
            service.start(initialLifecycleState: AppLifecycleState.resumed);
            await pumpEventQueue();
            expect(gateway.sentTypes, isNot(contains(subscribeType)));
            focus('thread-b');
            databaseOpenGate!.complete();
            final subscribe = await gateway.nextOutgoing(subscribeType);
            expect(subscribe['focused'], target('thread-b'));

            await accept(subscribe['requestId']! as String);

            expect(focusFrames(), isEmpty);
          },
        );
      }
    });
  }
}
