import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;
  late SessionCatalogCacheRepository repository;
  late FakeConversationContentGateway gateway;
  late ConversationContentSyncService service;

  Future<Database> openFfi(String databasePath, OpenDatabaseOptions options) =>
      databaseFactoryFfi.openDatabase(databasePath, options: options);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'ccpocket_conversation_content_sync_test_',
    );
    repository = SessionCatalogCacheRepository(
      SessionCatalogCacheDatabase(
        databasePath: path.join(temporaryDirectory.path, 'cache.db'),
        openDatabase: openFfi,
      ),
    );
    gateway = FakeConversationContentGateway();
    service = ConversationContentSyncService(bridge: gateway, cache: repository)
      ..start(initialLifecycleState: AppLifecycleState.resumed);
  });

  tearDown(() async {
    await service.dispose();
    await repository.close();
    await gateway.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('commits a complete snapshot before acknowledging it', () async {
    final subscribe = await gateway.nextOutgoing(
      'conversation_content_subscribe',
    );
    final subscriptionId = subscribe['requestId']! as String;
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.subscribed,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        requestId: subscriptionId,
        hotConversationLimit: 10,
      ),
    );
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.snapshotBegin,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-1',
        revision: 'revision-1',
        entryCount: 1,
        pageCount: 1,
        hasEarlier: true,
        sourceEntryCount: 400,
      ),
    );
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.snapshotPage,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-1',
        revision: 'revision-1',
        pageIndex: 0,
        pageCount: 1,
        entries: [_wireEntry('entry-1', 0)],
      ),
    );
    expect(
      gateway.sentTypes.where((type) => type == 'conversation_content_ack'),
      isEmpty,
    );
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.snapshotComplete,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-1',
        revision: 'revision-1',
        entryCount: 1,
        hasEarlier: true,
        sourceEntryCount: 400,
      ),
    );

    final ack = await gateway.nextOutgoing('conversation_content_ack');
    expect(ack['revision'], 'revision-1');
    final cached = await repository.loadConversationWindow(
      target: SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket',
      ),
      provider: 'codex',
      providerSessionId: 'thread-1',
    );
    expect(cached?.revision, 'revision-1');
    expect(cached?.entries.single.entryId, 'entry-1');
  });

  test('background lifecycle unsubscribes and rejects body events', () async {
    final subscribe = await gateway.nextOutgoing(
      'conversation_content_subscribe',
    );
    final subscriptionId = subscribe['requestId']! as String;
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.subscribed,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        requestId: subscriptionId,
        hotConversationLimit: 10,
      ),
    );
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await gateway.nextOutgoing('conversation_content_unsubscribe');

    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.patch,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-1',
        baseRevision: 'revision-1',
        revision: 'revision-2',
        entries: [_wireEntry('entry-2', 1)],
        hasEarlier: false,
        sourceEntryCount: 2,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      await repository.knownConversationRevisions(
        SessionCatalogCacheTarget.fromBridge(bridgeInstanceId: 'bridge-1'),
      ),
      isEmpty,
    );
  });
}

ConversationContentWireEntry _wireEntry(String id, int index) {
  return ConversationContentWireEntry(
    entryId: id,
    index: index,
    contentHash: 'hash-$id',
    rawMessage: const {'type': 'status', 'status': 'idle'},
  );
}

class FakeConversationContentGateway implements ConversationContentSyncGateway {
  final StreamController<BridgeConnectionState> _connections =
      StreamController<BridgeConnectionState>.broadcast();
  final StreamController<List<SessionInfo>> _sessions =
      StreamController<List<SessionInfo>>.broadcast();
  final StreamController<LocalFeatureServerMessage> _messages =
      StreamController<LocalFeatureServerMessage>.broadcast();
  final StreamController<ClientDeliveryModeStateMessage> _deliveryModes =
      StreamController<ClientDeliveryModeStateMessage>.broadcast();
  final StreamController<Map<String, dynamic>> _outgoing =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  List<String> get sentTypes =>
      sent.map((message) => message['type']! as String).toList();

  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessions.stream;

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      _messages.stream;

  @override
  Stream<ClientDeliveryModeStateMessage> get clientDeliveryModeStates =>
      _deliveryModes.stream;

  @override
  BridgeConnectionState currentBridgeConnectionState =
      BridgeConnectionState.connected;

  @override
  String? bridgeInstanceId = 'bridge-1';

  @override
  String? logicalConnectionIdentity = 'machine:1';

  @override
  String? lastUrl = 'wss://bridge.example/socket?token=secret';

  @override
  bool supportsConversationContentEvents = true;

  @override
  BridgeClientDeliveryMode desiredClientDeliveryMode =
      BridgeClientDeliveryMode.interactive;

  @override
  void send(ClientMessage message) {
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    sent.add(json);
    _outgoing.add(json);
  }

  void addEvent(ConversationContentEventMessage message) {
    _messages.add(message);
  }

  Future<Map<String, dynamic>> nextOutgoing(String type) async {
    for (final message in sent) {
      if (message['type'] == type && message['_observed'] != true) {
        message['_observed'] = true;
        return message;
      }
    }
    return _outgoing.stream.firstWhere((message) => message['type'] == type);
  }

  Future<void> close() async {
    await Future.wait([
      _connections.close(),
      _sessions.close(),
      _messages.close(),
      _deliveryModes.close(),
      _outgoing.close(),
    ]);
  }
}
