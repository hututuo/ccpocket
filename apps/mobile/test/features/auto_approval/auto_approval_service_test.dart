import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/auto_approval/auto_approval_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final _sessionsController = StreamController<List<SessionInfo>>.broadcast();
  final _connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final _featureController =
      StreamController<LocalFeatureServerMessage>.broadcast();
  final sent = <Map<String, dynamic>>[];
  final sentDeliveries = <ClientMessageDelivery>[];

  List<SessionInfo> currentSessions = [_session()];
  bool connected = true;
  String? url = 'wss://bridge.example.test:8765/ws';
  String? logicalIdentity;
  int sessionListRequests = 0;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionsController.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _connectionController.stream;

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      _featureController.stream;

  @override
  List<SessionInfo> get sessions => currentSessions;

  @override
  bool get isConnected => connected;

  @override
  String? get lastUrl => url;

  @override
  String? get logicalConnectionIdentity => logicalIdentity;

  @override
  void requestSessionList() => sessionListRequests += 1;

  @override
  void send(ClientMessage message) {
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
    sentDeliveries.add(message.delivery);
  }

  void emitSessions(List<SessionInfo> sessions) {
    currentSessions = sessions;
    _sessionsController.add(sessions);
  }

  void emitConnection(BridgeConnectionState state) {
    connected = state == BridgeConnectionState.connected;
    _connectionController.add(state);
  }

  void emitFeature(LocalFeatureServerMessage message) {
    _featureController.add(message);
  }

  @override
  void dispose() {
    _sessionsController.close();
    _connectionController.close();
    _featureController.close();
    super.dispose();
  }
}

SessionInfo _session({
  String runtimeId = 'runtime-1',
  String? stableId = 'thread-1',
  String provider = 'codex',
  PermissionRequestMessage? pending,
}) => SessionInfo(
  id: runtimeId,
  provider: provider,
  projectPath: '/tmp/project',
  claudeSessionId: stableId,
  status: pending == null ? 'running' : 'waiting_approval',
  createdAt: '2026-07-18T00:00:00Z',
  lastActivityAt: '2026-07-18T00:00:00Z',
  pendingPermission: pending,
);

Future<
  ({_Bridge bridge, AutoApprovalService service, SharedPreferences preferences})
>
_harness({
  Map<String, Object> initialPreferences = const {},
  Duration timeout = const Duration(seconds: 1),
}) async {
  SharedPreferences.setMockInitialValues(initialPreferences);
  final preferences = await SharedPreferences.getInstance();
  final bridge = _Bridge();
  final service = AutoApprovalService(
    bridge: bridge,
    preferences: preferences,
    requestTimeout: timeout,
  )..initialize();
  await Future<void>.delayed(Duration.zero);
  return (bridge: bridge, service: service, preferences: preferences);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Mobile advertises and sends only the Bridge state protocol', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);

    expect(harness.bridge.sent, hasLength(1));
    expect(harness.bridge.sent.single, {
      'type': 'get_auto_approval_state',
      'sessionId': 'runtime-1',
      'requestId': isA<String>(),
    });
    expect(
      harness.bridge.sentDeliveries.single,
      ClientMessageDelivery.ephemeral,
    );
    expect(
      LocalFeatureProtocolHost.supportedServerMessageTypes,
      contains(autoApprovalStateCapability),
    );
    expect(
      harness.bridge.sent.where((message) => message['type'] == 'approve'),
      isEmpty,
    );
  });

  test('toggle waits for and adopts authoritative Bridge state', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    _answerLatestQuery(harness.bridge, enabled: false, count: 0);
    await Future<void>.delayed(Duration.zero);

    final update = harness.service.setEnabledForSession('runtime-1', true);
    expect(harness.service.isEnabledForSession('runtime-1'), isTrue);
    final request = harness.bridge.sent.last;
    expect(request['type'], 'set_auto_approval');
    expect(request['enabled'], isTrue);
    harness.bridge.emitFeature(
      AutoApprovalStateMessage(
        sessionId: 'runtime-1',
        requestId: request['requestId'] as String,
        providerSessionId: 'thread-1',
        enabled: true,
        enabledConversationCount: 1,
        approvedCount: 0,
        reason: 'updated',
      ),
    );

    expect(await update, isTrue);
    expect(harness.service.isEnabledForSession('runtime-1'), isTrue);
    expect(harness.service.enabledConversationCount, 1);
  });

  test('permission snapshots never cause Mobile to send approve', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    harness.bridge.emitSessions([
      _session(
        pending: const PermissionRequestMessage(
          toolUseId: 'dangerous',
          toolName: 'Bash',
          input: {'command': 'rm -rf build'},
        ),
      ),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(
      harness.bridge.sent.where((message) => message['type'] == 'approve'),
      isEmpty,
    );
  });

  test('old Bridge capability failure disables the session control', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    final query = harness.bridge.sent.single;
    harness.bridge.emitFeature(
      LocalFeatureRequestErrorMessage(
        featureId: 'auto_approval',
        ownerSessionId: 'runtime-1',
        requestType: 'get_auto_approval_state',
        requestId: query['requestId'] as String,
        errorCode: 'unsupported_message',
        message: 'get_auto_approval_state',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.service.canConfigureSession('runtime-1'), isFalse);
    expect(
      await harness.service.setEnabledForSession('runtime-1', true),
      isFalse,
    );
  });

  test('independent app-server boundary is retained for explicit UI', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    final query = harness.bridge.sent.single;
    harness.bridge.emitFeature(
      AutoApprovalStateMessage(
        sessionId: 'runtime-1',
        requestId: query['requestId'] as String,
        enabledConversationCount: 0,
        supervisionAvailable: false,
        unavailableReason: 'external_app_server',
        reason: 'query',
        error: 'independent server',
        errorCode: 'external_app_server_approval_unsupported',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.service.canConfigureSession('runtime-1'), isFalse);
    expect(
      harness.service.unavailableReasonForSession('runtime-1'),
      'external_app_server',
    );
  });

  test(
    'enabled policy becomes ineffective without being erased by external ownership',
    () async {
      final harness = await _harness();
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);
      _answerLatestQuery(harness.bridge, enabled: true, count: 1);
      await Future<void>.delayed(Duration.zero);

      expect(harness.service.isEnabledForSession('runtime-1'), isTrue);
      expect(harness.service.isEffectiveForSession('runtime-1'), isTrue);
      harness.bridge.emitFeature(
        const AutoApprovalStateMessage(
          sessionId: 'runtime-1',
          enabledConversationCount: 1,
          supervisionAvailable: false,
          unavailableReason: 'external_app_server',
          reason: 'query',
          error: 'independent server',
          errorCode: 'external_app_server_approval_unsupported',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(harness.service.isEnabledForSession('runtime-1'), isTrue);
      expect(harness.service.isEffectiveForSession('runtime-1'), isFalse);
      expect(harness.service.enabledConversationCount, 1);
    },
  );

  test(
    'imports matching legacy identities once and clears Mobile ownership',
    () async {
      final legacy = jsonEncode([
        1,
        'endpoint:wss://bridge.example.test:8765/ws',
        'codex',
        'thread-1',
      ]);
      final otherMachine = jsonEncode([
        1,
        'machine:other',
        'codex',
        'thread-other',
      ]);
      final harness = await _harness(
        initialPreferences: {
          AutoApprovalService.preferencesKey: [legacy, otherMachine],
        },
      );
      addTearDown(harness.service.dispose);
      addTearDown(harness.bridge.dispose);

      final import = harness.bridge.sent.singleWhere(
        (message) => message['type'] == 'import_legacy_auto_approvals',
      );
      expect(import['providerSessionIds'], ['thread-1']);
      harness.bridge.emitFeature(
        AutoApprovalStateMessage(
          sessionId: 'bridge-auto-approval',
          requestId: import['requestId'] as String,
          enabledConversationCount: 1,
          reason: 'legacy_imported',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final refreshedQuery = harness.bridge.sent.lastWhere(
        (message) => message['type'] == 'get_auto_approval_state',
      );
      harness.bridge.emitFeature(
        AutoApprovalStateMessage(
          sessionId: 'runtime-1',
          requestId: refreshedQuery['requestId'] as String,
          providerSessionId: 'thread-1',
          enabled: true,
          enabledConversationCount: 1,
          approvedCount: 0,
          reason: 'query',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.preferences.getStringList(AutoApprovalService.preferencesKey),
        [otherMachine],
      );
      expect(harness.service.isEnabledForSession('runtime-1'), isTrue);
    },
  );

  test('backend broadcasts update approval count without a request', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    harness.bridge.emitFeature(
      const AutoApprovalStateMessage(
        sessionId: 'runtime-1',
        providerSessionId: 'thread-1',
        enabled: true,
        enabledConversationCount: 1,
        approvedCount: 3,
        reason: 'auto_approved',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.service.isEnabledForSession('runtime-1'), isTrue);
    expect(harness.service.approvedCountForSession('runtime-1'), 3);
  });

  test('offline emergency stop is queued and sent after reconnect', () async {
    final harness = await _harness();
    addTearDown(harness.service.dispose);
    addTearDown(harness.bridge.dispose);
    _answerLatestQuery(harness.bridge, enabled: true, count: 1);
    await Future<void>.delayed(Duration.zero);
    harness.bridge.emitConnection(BridgeConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);

    expect(await harness.service.disableAll(), isTrue);
    expect(harness.service.enabledConversationCount, 0);
    expect(
      harness.preferences.getBool(
        'local_feature.codex_auto_approval.disable_on_reconnect.v1',
      ),
      isTrue,
    );
    harness.bridge.emitConnection(BridgeConnectionState.connected);
    await Future<void>.delayed(Duration.zero);

    final request = harness.bridge.sent.lastWhere(
      (message) => message['type'] == 'disable_all_auto_approvals',
    );
    harness.bridge.emitFeature(
      AutoApprovalStateMessage(
        sessionId: 'bridge-auto-approval',
        requestId: request['requestId'] as String,
        enabledConversationCount: 0,
        reason: 'disabled_all',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(harness.service.isEnabledForSession('runtime-1'), isFalse);
    expect(
      harness.preferences.getBool(
        'local_feature.codex_auto_approval.disable_on_reconnect.v1',
      ),
      isNull,
    );
  });

  test('sanitizes logical endpoint identity without credentials', () {
    expect(
      AutoApprovalService.sanitizeBridgeEndpoint(
        'WSS://Token@Bridge.Example.Test:9443/ws?secret=hidden#fragment',
      ),
      'wss://bridge.example.test:9443/ws',
    );
    expect(
      AutoApprovalService.sanitizeBridgeEndpoint('https://example.test'),
      isNull,
    );
  });
}

void _answerLatestQuery(
  _Bridge bridge, {
  required bool enabled,
  required int count,
}) {
  final request = bridge.sent.lastWhere(
    (message) => message['type'] == 'get_auto_approval_state',
  );
  bridge.emitFeature(
    AutoApprovalStateMessage(
      sessionId: request['sessionId'] as String,
      requestId: request['requestId'] as String,
      providerSessionId: 'thread-1',
      enabled: enabled,
      enabledConversationCount: count,
      approvedCount: 0,
      reason: 'query',
    ),
  );
}
