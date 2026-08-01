import 'dart:convert';

import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/notification_preferences.dart';
import 'package:ccpocket/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NotificationService.instance.configure(NotificationPreferences.defaults);
    NotificationService.instance.clearActiveSession();
  });

  test(
    'applies category and foreground policy before showing remote alerts',
    () {
      NotificationService.instance.configure(
        const NotificationPreferences(
          taskCompleted: true,
          progress: false,
          showWhileAppOpen: false,
        ),
      );

      expect(
        NotificationService.instance.allowsRemoteEvent(
          NotificationPreferences.sessionProgressEvent,
          appIsForeground: false,
        ),
        isFalse,
      );
      expect(
        NotificationService.instance.allowsRemoteEvent(
          NotificationPreferences.sessionCompletedEvent,
          appIsForeground: true,
        ),
        isFalse,
      );
      expect(
        NotificationService.instance.allowsRemoteEvent(
          NotificationPreferences.sessionCompletedEvent,
          appIsForeground: false,
        ),
        isTrue,
      );
    },
  );

  test('active sessions are isolated by Codex source when available', () {
    const firstSource = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-a',
    );
    const secondSource = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-source-b',
    );
    NotificationService.instance.setActiveSession(
      sessionId: 'shared-thread',
      provider: 'codex',
      dataSourceIdentity: firstSource,
    );

    expect(
      NotificationService.instance.isActiveSession(
        sessionId: 'shared-thread',
        provider: 'codex',
        dataSourceIdentity: firstSource,
      ),
      isTrue,
    );
    expect(
      NotificationService.instance.isActiveSession(
        sessionId: 'shared-thread',
        provider: 'codex',
        dataSourceIdentity: secondSource,
      ),
      isFalse,
    );

    // A route observer with no source detail must not erase a source-aware
    // identity already published by the visible session screen.
    NotificationService.instance.setActiveSession(
      sessionId: 'shared-thread',
      provider: 'codex',
    );
    expect(NotificationService.instance.activeDataSourceIdentity, firstSource);
  });

  test('notification payload carries opaque data-source identity', () {
    final payload =
        jsonDecode(
              encodeSessionNotificationPayload(
                sessionId: 'runtime-1',
                provider: 'codex',
                dataSourceIdentity: const BridgeDataSourceIdentity(
                  bridgeInstanceId: 'bridge-1',
                  codexSourceId: 'codex-source-a',
                ),
              ),
            )
            as Map<String, dynamic>;

    expect(payload['bridgeInstanceId'], 'bridge-1');
    expect(payload['codexSourceId'], 'codex-source-a');
  });

  test('Codex broker notification payload keeps the exact v2 fence', () {
    final payload =
        jsonDecode(
              encodeSessionNotificationPayload(
                sessionId: 'thread-1',
                provider: 'codex',
                eventType: 'approval_required',
                permissionId: 'must-not-be-legacy',
                actionPayloadVersion: '2',
                opaqueRequestId: 'opaque-1',
                codexSourceId: 'source-1',
                threadId: 'thread-1',
                turnId: 'turn-1',
                authorityGeneration: 'cab:1:1',
                allowedActions: 'approve,reject',
                dataSourceIdentity: const BridgeDataSourceIdentity(
                  bridgeInstanceId: 'bridge-1',
                  codexSourceId: 'source-1',
                ),
              ),
            )
            as Map<String, dynamic>;

    expect(payload['actionPayloadVersion'], '2');
    expect(payload['opaqueRequestId'], 'opaque-1');
    expect(payload['permissionId'], isNull);
    expect(hasCodexActionBrokerApprovalPayload(payload), isTrue);
    expect(
      hasCodexActionBrokerApprovalPayload(<String, dynamic>{
        ...payload,
        'allowedActions': 'approve,delete',
      }),
      isFalse,
    );
  });
}
