import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/side_chat/state/ephemeral_side_chat_registry_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements EphemeralSideChatBridgeGateway {
  final connectionController =
      StreamController<BridgeConnectionState>.broadcast(sync: true);
  final capabilityController = StreamController<void>.broadcast(sync: true);
  final messageController =
      StreamController<LocalFeatureServerMessage>.broadcast(sync: true);
  final stoppedController = StreamController<String>.broadcast(sync: true);
  final sent = <ClientMessage>[];

  @override
  bool isConnected = false;

  @override
  String? logicalConnectionIdentity;

  @override
  Set<String> capabilities = {};

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      connectionController.stream;

  @override
  Stream<void> get capabilityChanges => capabilityController.stream;

  @override
  Stream<LocalFeatureServerMessage> get messages => messageController.stream;

  @override
  Stream<String> get stoppedSessions => stoppedController.stream;

  @override
  void send(ClientMessage message) => sent.add(message);

  Map<String, dynamic> sentJson(int index) =>
      jsonDecode(sent[index].toJson()) as Map<String, dynamic>;

  Future<void> close() async {
    await connectionController.close();
    await capabilityController.close();
    await messageController.close();
    await stoppedController.close();
  }
}

EphemeralSideChatEntry _entry({
  String childSessionId = 'child-1',
  String parentSessionId = 'parent-1',
  String? parentProviderSessionId,
  String status = 'idle',
}) => EphemeralSideChatEntry(
  childSessionId: childSessionId,
  parentSessionId: parentSessionId,
  parentProviderSessionId: parentProviderSessionId,
  projectPath: '/tmp/project',
  status: status,
  createdAt: DateTime.utc(2026, 7, 25),
  lastActivityAt: DateTime.utc(2026, 7, 25, 0, 0, 1),
);

void main() {
  test(
    'reconciles on connect and preserves the registry while disconnected',
    () async {
      final gateway = _Gateway();
      final service = EphemeralSideChatRegistryService(
        bridge: gateway,
        requestTimeout: const Duration(seconds: 1),
      );

      gateway.capabilities = {ephemeralSideChatCapability};
      gateway.isConnected = true;
      gateway.connectionController.add(BridgeConnectionState.connected);

      expect(gateway.sent, hasLength(1));
      final requestId = gateway.sentJson(0)['requestId'] as String;
      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: requestId,
          entries: [_entry()],
        ),
      );
      await service.refresh();
      expect(service.entries.single.childSessionId, 'child-1');

      gateway.isConnected = false;
      gateway.connectionController.add(BridgeConnectionState.reconnecting);
      expect(service.entries.single.childSessionId, 'child-1');

      service.dispose();
      await gateway.close();
    },
  );

  test(
    'sends canonical parent identity only to a Bridge that advertises it',
    () async {
      final gateway = _Gateway()
        ..capabilities = {
          ephemeralSideChatCapability,
          ephemeralSideChatParentIdentityCapability,
        }
        ..isConnected = true;
      final service = EphemeralSideChatRegistryService(
        bridge: gateway,
        requestTimeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      final refreshId = gateway.sentJson(0)['requestId'] as String;
      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: refreshId,
          entries: const [],
        ),
      );

      final openFuture = service.open(
        'runtime-parent',
        parentProviderSessionId: 'durable-thread',
      );
      final openRequest = gateway.sentJson(1);
      expect(openRequest, containsPair('parentSessionId', 'runtime-parent'));
      expect(
        openRequest,
        containsPair('parentProviderSessionId', 'durable-thread'),
      );
      final entry = _entry(
        parentSessionId: 'runtime-parent',
        parentProviderSessionId: 'durable-thread',
      );
      gateway.messageController.add(
        EphemeralSideChatOpenedMessage(
          parentSessionId: 'runtime-parent',
          requestId: openRequest['requestId'] as String,
          entry: entry,
        ),
      );
      await openFuture;
      expect(service.entriesForParent('durable-thread'), [entry]);
      expect(service.entriesForParent('runtime-parent'), isEmpty);

      service.dispose();
      await gateway.close();
    },
  );

  test('omits canonical parent identity for a legacy Bridge', () async {
    final gateway = _Gateway()
      ..capabilities = {ephemeralSideChatCapability}
      ..isConnected = true;
    final service = EphemeralSideChatRegistryService(
      bridge: gateway,
      requestTimeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    final refreshId = gateway.sentJson(0)['requestId'] as String;
    gateway.messageController.add(
      EphemeralSideChatRegistryMessage(requestId: refreshId, entries: const []),
    );

    final openFuture = service.open(
      'runtime-parent',
      parentProviderSessionId: 'durable-thread',
    );
    final openRequest = gateway.sentJson(1);
    expect(openRequest, isNot(contains('parentProviderSessionId')));
    gateway.messageController.add(
      EphemeralSideChatOpenedMessage(
        parentSessionId: 'runtime-parent',
        requestId: openRequest['requestId'] as String,
        entry: _entry(parentSessionId: 'runtime-parent'),
      ),
    );
    await openFuture;

    service.dispose();
    await gateway.close();
  });

  test(
    'opens, lists, closes, and removes stopped children authoritatively',
    () async {
      final gateway = _Gateway()
        ..capabilities = {ephemeralSideChatCapability}
        ..isConnected = true;
      final service = EphemeralSideChatRegistryService(
        bridge: gateway,
        requestTimeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);

      final refreshId = gateway.sentJson(0)['requestId'] as String;
      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: refreshId,
          entries: const [],
        ),
      );

      final openFuture = service.open('parent-1');
      final openRequest = gateway.sentJson(1);
      gateway.messageController.add(
        EphemeralSideChatOpenedMessage(
          parentSessionId: 'parent-1',
          requestId: openRequest['requestId'] as String,
          entry: _entry(),
        ),
      );
      expect((await openFuture).childSessionId, 'child-1');
      expect(service.entriesForParent('parent-1'), hasLength(1));

      final closeFuture = service.close('child-1');
      final closeRequest = gateway.sentJson(2);
      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: closeRequest['requestId'] as String,
          entries: const [],
        ),
      );
      await closeFuture;
      expect(service.entries, isEmpty);

      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(entries: [_entry()]),
      );
      gateway.stoppedController.add('child-1');
      expect(service.entries, isEmpty);

      service.dispose();
      await gateway.close();
    },
  );

  test(
    'fails pending requests on disconnect and clears stale entries on an unsupported Bridge',
    () async {
      final gateway = _Gateway()
        ..capabilities = {ephemeralSideChatCapability}
        ..isConnected = true;
      final service = EphemeralSideChatRegistryService(
        bridge: gateway,
        requestTimeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      final refreshId = gateway.sentJson(0)['requestId'] as String;
      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: refreshId,
          entries: [_entry()],
        ),
      );

      final openFuture = service.open('parent-1');
      gateway.isConnected = false;
      gateway.connectionController.add(BridgeConnectionState.disconnected);
      await expectLater(openFuture, throwsStateError);
      expect(service.entries, hasLength(1));

      gateway.capabilities = {};
      gateway.isConnected = true;
      gateway.connectionController.add(BridgeConnectionState.connected);
      expect(service.entries, isEmpty);

      service.dispose();
      await gateway.close();
    },
  );

  test(
    'clears old entries and rejects late responses when the Bridge changes',
    () async {
      final gateway = _Gateway()
        ..logicalConnectionIdentity = 'bridge-a'
        ..capabilities = {ephemeralSideChatCapability}
        ..isConnected = true;
      final service = EphemeralSideChatRegistryService(
        bridge: gateway,
        requestTimeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);

      final firstRequestId = gateway.sentJson(0)['requestId'] as String;
      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: firstRequestId,
          entries: [_entry(childSessionId: 'child-a')],
        ),
      );
      expect(service.entries.single.childSessionId, 'child-a');
      await Future<void>.delayed(Duration.zero);

      final oldRefresh = service.refresh();
      final oldRefreshExpectation = expectLater(oldRefresh, throwsStateError);
      final oldRequestId = gateway.sentJson(1)['requestId'] as String;
      gateway.logicalConnectionIdentity = 'bridge-b';
      gateway.connectionController.add(BridgeConnectionState.connecting);
      await oldRefreshExpectation;
      expect(service.entries, isEmpty);

      gateway.connectionController.add(BridgeConnectionState.connected);
      final currentRequestId = gateway.sentJson(2)['requestId'] as String;
      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: oldRequestId,
          entries: [_entry(childSessionId: 'stale-child')],
        ),
      );
      expect(service.entries, isEmpty);

      gateway.messageController.add(
        EphemeralSideChatRegistryMessage(
          requestId: currentRequestId,
          entries: [_entry(childSessionId: 'child-b')],
        ),
      );
      expect(service.entries.single.childSessionId, 'child-b');

      gateway.messageController.add(
        EphemeralSideChatOpenedMessage(
          parentSessionId: 'parent-1',
          requestId: 'late-open-from-bridge-a',
          entry: _entry(childSessionId: 'late-child'),
        ),
      );
      expect(service.entries.single.childSessionId, 'child-b');

      service.dispose();
      await gateway.close();
    },
  );
}
