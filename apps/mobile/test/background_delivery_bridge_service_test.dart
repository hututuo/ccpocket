import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/background_sync/background_sync_coordinator.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'offline foreground restoration resets the desired delivery mode',
    () async {
      final bridge = BridgeService();
      addTearDown(bridge.dispose);

      expect(
        await bridge.setClientDeliveryMode(
          mode: BridgeClientDeliveryMode.notificationsOnly,
        ),
        isNull,
      );
      expect(
        bridge.desiredClientDeliveryMode,
        BridgeClientDeliveryMode.notificationsOnly,
      );
      expect(
        bridge.acknowledgeBackgroundNotification('delivery-offline'),
        isFalse,
      );

      expect(
        await bridge.setClientDeliveryMode(
          mode: BridgeClientDeliveryMode.interactive,
        ),
        isNull,
      );
      expect(
        bridge.desiredClientDeliveryMode,
        BridgeClientDeliveryMode.interactive,
      );
    },
  );

  test(
    'notification-only mode rejects full stream messages before normal routing',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      server.transform(WebSocketTransformer()).listen((socket) {
        socketReady.complete(socket);
      });
      addTearDown(() => server.close(force: true));

      final bridge = BridgeService();
      addTearDown(bridge.dispose);
      bridge.connect('ws://127.0.0.1:${server.port}');
      final socket = await socketReady.future;
      final incoming = socket.map((data) {
        return jsonDecode(data as String) as Map<String, dynamic>;
      }).asBroadcastStream();
      final modeRequests = incoming.where(
        (message) => message['type'] == 'set_client_delivery_mode',
      );
      final ackRequests = incoming.where(
        (message) => message['type'] == 'background_notification_ack_v1',
      );

      socket.add(
        jsonEncode({
          'type': 'session_list',
          'sessions': <Object>[],
          'bridgeCapabilities': const [
            backgroundNotificationDeliveryBridgeCapability,
            backgroundNotificationDeliveryAckBridgeCapability,
          ],
        }),
      );
      await _waitUntil(() => bridge.supportsBackgroundNotificationDelivery);

      final routedMessages = <ServerMessage>[];
      final notifications = <BackgroundNotificationMessage>[];
      final routedSubscription = bridge.messages.listen(routedMessages.add);
      final notificationSubscription = bridge.backgroundNotifications.listen(
        notifications.add,
      );
      addTearDown(routedSubscription.cancel);
      addTearDown(notificationSubscription.cancel);

      final notificationsOnly = bridge.setClientDeliveryMode(
        mode: BridgeClientDeliveryMode.notificationsOnly,
        locale: 'zh',
        privacyMode: true,
        enabledEventTypes: const ['session_completed'],
      );
      final backgroundRequest = await modeRequests.first;
      expect(backgroundRequest['mode'], 'notifications_only');
      socket.add(
        jsonEncode({
          'type': 'client_delivery_mode_state_v1',
          'requestId': backgroundRequest['requestId'],
          'mode': 'notifications_only',
          'activeWorkCount': 1,
        }),
      );
      expect(
        (await notificationsOnly)?.mode,
        BridgeClientDeliveryMode.notificationsOnly,
      );
      expect(bridge.backgroundActiveWorkCount, 1);

      socket
        ..add(
          jsonEncode({
            'type': 'status',
            'sessionId': 'session-1',
            'status': 'running',
          }),
        )
        ..add(
          jsonEncode({
            'type': 'error',
            'errorCode': 'session_runtime_error',
            'message': 'sensitive background failure detail',
          }),
        )
        ..add(
          jsonEncode({
            'type': 'background_notification_v1',
            'deliveryId': 'delivery-1',
            'eventType': 'session_completed',
            'sessionId': 'session-1',
            'provider': 'codex',
            'title': '任务完成',
            'body': '点开后增量同步',
            'occurredAt': '2026-07-24T00:00:00.000Z',
          }),
        );
      await _waitUntil(() => notifications.isNotEmpty);

      expect(routedMessages, isEmpty);
      expect(notifications.single.sessionId, 'session-1');
      expect(notifications.single.deliveryId, 'delivery-1');

      final ackRequest = ackRequests.first;
      expect(bridge.acknowledgeBackgroundNotification('delivery-1'), isTrue);
      expect(await ackRequest, {
        'type': 'background_notification_ack_v1',
        'deliveryId': 'delivery-1',
      });

      final interactive = bridge.setClientDeliveryMode(
        mode: BridgeClientDeliveryMode.interactive,
      );
      final interactiveRequest = await modeRequests.first;
      expect(interactiveRequest['mode'], 'interactive');
      socket.add(
        jsonEncode({
          'type': 'client_delivery_mode_state_v1',
          'requestId': interactiveRequest['requestId'],
          'mode': 'interactive',
          'activeWorkCount': 1,
        }),
      );
      expect((await interactive)?.mode, BridgeClientDeliveryMode.interactive);

      socket.add(
        jsonEncode({
          'type': 'background_activity_state_v1',
          'activeWorkCount': 2,
          'occurredAt': '2026-07-24T00:00:01.000Z',
        }),
      );
      await _waitUntil(() => bridge.backgroundActiveWorkCount == 2);
      expect(
        BridgeServiceBackgroundSyncGateway(bridge).hasBackgroundWork,
        isTrue,
      );

      socket.add(
        jsonEncode({
          'type': 'status',
          'sessionId': 'session-1',
          'status': 'running',
        }),
      );
      await _waitUntil(
        () => routedMessages.whereType<StatusMessage>().isNotEmpty,
      );
      expect(routedMessages.whereType<StatusMessage>(), hasLength(1));
    },
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met before timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
