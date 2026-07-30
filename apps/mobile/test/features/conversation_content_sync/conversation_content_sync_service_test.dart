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

  test('prefers v2 and ACKs timeline pages only after SQLite commit', () async {
    await service.dispose();
    gateway.supportsConversationSyncV2 = true;
    service = ConversationContentSyncService(bridge: gateway, cache: repository)
      ..start(initialLifecycleState: AppLifecycleState.resumed);

    final subscribe = await gateway.nextOutgoing('conversation_sync_subscribe');
    final subscriptionId = subscribe['requestId']! as String;
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.syncBegin,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-1',
        sequence: 1,
        requestId: subscriptionId,
        catalogState: 'catalog-1',
        statusState: 'status-1',
      ),
    );
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      1,
    );

    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.catalogChanges,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-1',
        sequence: 2,
        catalogState: 'catalog-1',
        pageIndex: 0,
        pageCount: 1,
        created: [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-v2',
            revision: 'revision-1',
            projectPath: '/workspace/v2',
            name: 'V2 thread',
            createdAt: '2026-07-30T00:00:00.000Z',
            modifiedAt: '2026-07-30T00:01:00.000Z',
            recencyAt: '2026-07-30T00:02:00.000Z',
            availability: 'durable',
          ),
        ],
      ),
    );
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      2,
    );

    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.timelinePage,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-1',
        sequence: 3,
        provider: 'codex',
        providerSessionId: 'thread-v2',
        revision: 'revision-1',
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 2,
        entries: [_wireEntry('entry-1', 0)],
        hasEarlier: true,
        turnsNextCursor: 'older-turns-1',
        sourceEntryCount: 50,
      ),
    );
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      3,
    );
    expect(
      await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-v2',
      ),
      isNull,
    );

    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.timelinePage,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-1',
        sequence: 4,
        provider: 'codex',
        providerSessionId: 'thread-v2',
        revision: 'revision-1',
        mode: 'snapshot',
        pageIndex: 1,
        pageCount: 2,
        entries: [_wireEntry('entry-2', 1)],
        hasEarlier: true,
        turnsNextCursor: 'older-turns-1',
        sourceEntryCount: 50,
      ),
    );
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      4,
    );
    final cached = await service.loadCachedWindow(
      provider: 'codex',
      providerSessionId: 'thread-v2',
    );
    expect(cached?.entries.map((entry) => entry.entryId), [
      'entry-1',
      'entry-2',
    ]);
    expect(cached?.turnsNextCursor, 'older-turns-1');

    final priorityReady = service.syncUpdates.firstWhere(
      (update) => update.kind == ConversationSyncCacheUpdateKind.priorityReady,
    );
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.syncCheckpoint,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-1',
        sequence: 5,
        phase: 'priority',
        hasMore: true,
      ),
    );
    await priorityReady;
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      5,
    );
    expect(
      (await repository.loadConversationSyncState(
        SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      )).priorityReady,
      isTrue,
    );
  });

  test(
    'accepts later batches on one v2 subscription without resetting readiness',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
      )..start(initialLifecycleState: AppLifecycleState.resumed);
      final updates = <ConversationSyncCacheUpdate>[];
      final updatesSubscription = service.syncUpdates.listen(updates.add);
      addTearDown(updatesSubscription.cancel);

      final subscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final subscriptionId = subscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-initial',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-1',
          statusState: 'status-1',
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        1,
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncCheckpoint,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-initial',
          sequence: 2,
          phase: 'priority',
          hasMore: true,
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        2,
      );

      await service.markConversationRead(
        provider: 'codex',
        providerSessionId: 'thread-active',
        readAt: DateTime.utc(2026, 7, 30, 2),
      );
      await gateway.nextOutgoing('conversation_sync_read');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-incremental',
          sequence: 3,
          requestId: subscriptionId,
          catalogState: 'catalog-1',
          statusState: 'status-2',
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        3,
      );

      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
      );
      expect(
        (await repository.loadConversationSyncState(target)).priorityReady,
        isTrue,
      );
      expect(
        updates
            .where(
              (update) =>
                  update.kind == ConversationSyncCacheUpdateKind.started,
            )
            .length,
        1,
      );

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-incremental',
          sequence: 4,
          statusState: 'status-2',
          pageIndex: 0,
          pageCount: 1,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-active',
              activity: 'working',
              attention: 'none',
              result: 'none',
              runtimeAttachment: 'loaded',
              source: 'appServer',
              confidence: 'authoritative',
              observedAt: '2026-07-30T02:00:01.000Z',
            ),
          ],
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        4,
      );
      expect(
        (await repository.loadConversationStatuses(target)).single.activity,
        'working',
      );
      expect(
        gateway.sentTypes.where(
          (type) => type == 'conversation_sync_unsubscribe',
        ),
        isEmpty,
      );
    },
  );

  test(
    'sequence gaps restart without clearing committed target data',
    () async {
      await service.dispose();
      await repository.close();
      final trackingRepository = _FailingCatalogRepository(
        SessionCatalogCacheDatabase(
          databasePath: path.join(temporaryDirectory.path, 'gap-cache.db'),
          openDatabase: openFfi,
        ),
      );
      repository = trackingRepository;
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
        retryBaseDelay: const Duration(milliseconds: 40),
        retryMaxDelay: const Duration(milliseconds: 80),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final subscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final subscriptionId = subscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-gap',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-gap',
          statusState: 'status-gap',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        _catalogRecoveryEvent(
          subscriptionId: subscriptionId,
          batchId: 'batch-gap',
          sequence: 3,
          catalogState: 'catalog-gap',
        ),
      );

      await gateway.nextOutgoing('conversation_sync_unsubscribe');
      expect(trackingRepository.clearTargetCalls, 0);
    },
  );

  test(
    'commits a status reset and replacement page without resubscribing',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket',
      );
      await repository.applyConversationStatusPage(
        target: target,
        statusState: 'status-v1',
        pageIndex: 0,
        pageCount: 1,
        changes: const [
          ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'thread-status-reset',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-07-30T00:00:00.000Z',
          ),
        ],
      );

      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final subscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      expect(subscribe['statusState'], 'status-v1');
      final subscriptionId = subscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-status-reset',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-v2',
          statusState: 'status-v2',
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        1,
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncReset,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-status-reset',
          sequence: 2,
          scope: 'status',
          reason: 'state_unavailable',
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        2,
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-status-reset',
          sequence: 3,
          statusState: 'status-v2',
          pageIndex: 0,
          pageCount: 1,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-status-reset',
              activity: 'idle',
              attention: 'none',
              result: 'none',
              runtimeAttachment: 'notLoaded',
              source: 'appServer',
              confidence: 'unknown',
              observedAt: '2026-07-30T00:01:00.000Z',
            ),
          ],
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        3,
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncCheckpoint,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-status-reset',
          sequence: 4,
          phase: 'priority',
          hasMore: true,
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        4,
      );
      expect(
        gateway.sentTypes.where(
          (type) => type == 'conversation_sync_unsubscribe',
        ),
        isEmpty,
      );
      final state = await repository.loadConversationSyncState(target);
      expect(state.statusState, 'status-v2');
      expect(state.priorityReady, isTrue);
    },
  );

  test(
    'clears rebuildable cache once and preserves retry backoff after partial progress',
    () async {
      await service.dispose();
      await repository.close();
      final failingRepository = _FailingCatalogRepository(
        SessionCatalogCacheDatabase(
          databasePath: path.join(temporaryDirectory.path, 'failing-cache.db'),
          openDatabase: openFfi,
        ),
      );
      repository = failingRepository;
      gateway.supportsConversationSyncV2 = true;
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket',
      );
      await repository.storeReadWatermark(
        target: target,
        watermark: const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-recovery',
          readAt: '2026-07-30T00:00:00.000Z',
        ),
      );
      failingRepository.catalogFailuresRemaining = 2;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
        retryBaseDelay: const Duration(milliseconds: 40),
        retryMaxDelay: const Duration(milliseconds: 160),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final firstSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      expect(firstSubscribe['readWatermarks'], hasLength(1));
      final firstSubscriptionId = firstSubscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-recovery-1',
          sequence: 1,
          requestId: firstSubscriptionId,
          catalogState: 'catalog-recovery-1',
          statusState: 'status-recovery-1',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        _catalogRecoveryEvent(
          subscriptionId: firstSubscriptionId,
          batchId: 'batch-recovery-1',
          sequence: 2,
          catalogState: 'catalog-recovery-1',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_unsubscribe');
      expect(failingRepository.clearTargetCalls, 1);

      final secondSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      expect(secondSubscribe, isNot(contains('catalogState')));
      expect(secondSubscribe, isNot(contains('statusState')));
      expect(secondSubscribe['threadContentStates'], isEmpty);
      expect(secondSubscribe['readWatermarks'], hasLength(1));
      final secondSubscriptionId = secondSubscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-recovery-2',
          sequence: 1,
          requestId: secondSubscriptionId,
          catalogState: 'catalog-recovery-2',
          statusState: 'status-recovery-2',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        _catalogRecoveryEvent(
          subscriptionId: secondSubscriptionId,
          batchId: 'batch-recovery-2',
          sequence: 2,
          catalogState: 'catalog-recovery-2',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_unsubscribe');
      expect(failingRepository.clearTargetCalls, 1);

      final subscribeCount = gateway.sentTypes
          .where((type) => type == 'conversation_sync_subscribe')
          .length;
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(
        gateway.sentTypes
            .where((type) => type == 'conversation_sync_subscribe')
            .length,
        subscribeCount,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        gateway.sentTypes
            .where((type) => type == 'conversation_sync_subscribe')
            .length,
        subscribeCount + 1,
      );
    },
  );

  test('loads an older turn page into SQLite before cumulative ACK', () async {
    await service.dispose();
    gateway.supportsConversationSyncV2 = true;
    service = ConversationContentSyncService(bridge: gateway, cache: repository)
      ..start(initialLifecycleState: AppLifecycleState.resumed);

    final subscribe = await gateway.nextOutgoing('conversation_sync_subscribe');
    final subscriptionId = subscribe['requestId']! as String;
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.syncBegin,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-turn-page',
        sequence: 1,
        requestId: subscriptionId,
        catalogState: 'catalog-turn-page',
        statusState: 'status-turn-page',
      ),
    );
    await gateway.nextOutgoing('conversation_sync_ack');
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.timelinePage,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-turn-page',
        sequence: 2,
        provider: 'codex',
        providerSessionId: 'thread-turn-page',
        revision: 'revision-turn-page',
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_wireEntry('current-entry', 0)],
        hasEarlier: true,
        turnsNextCursor: 'cursor-1',
        sourceEntryCount: 2,
      ),
    );
    await gateway.nextOutgoing('conversation_sync_ack');

    final load = service.loadOlderTurns(
      provider: 'codex',
      providerSessionId: 'thread-turn-page',
    );
    final request = await gateway.nextOutgoing('conversation_turns_page');
    expect(request['cursor'], 'cursor-1');
    final requestId = request['requestId']! as String;
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.turnsPageResponse,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-turn-page',
        sequence: 3,
        requestId: requestId,
        provider: 'codex',
        providerSessionId: 'thread-turn-page',
        data: const [
          {
            'turnId': 'turn-earlier',
            'messages': [
              {
                'type': 'user_input',
                'text': 'Earlier prompt',
                'userMessageUuid': 'user-earlier',
              },
            ],
            'itemCount': 1,
            'itemsView': 'summary',
          },
        ],
        nextCursor: null,
      ),
    );

    final result = await load;
    expect(result.loaded, isTrue);
    expect(result.hasMore, isFalse);
    final cached = await service.loadCachedWindow(
      provider: 'codex',
      providerSessionId: 'thread-turn-page',
    );
    expect(cached?.entries.map((entry) => entry.entryId), [
      'user:user-earlier',
      'current-entry',
    ]);
    expect(cached?.turnsNextCursor, isNull);
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      3,
    );
  });

  test('loads detached tool details by provider turn before ACK', () async {
    await service.dispose();
    gateway.supportsConversationSyncV2 = true;
    gateway.supportsConversationItemsById = true;
    service = ConversationContentSyncService(bridge: gateway, cache: repository)
      ..start(initialLifecycleState: AppLifecycleState.resumed);

    final subscribe = await gateway.nextOutgoing('conversation_sync_subscribe');
    final subscriptionId = subscribe['requestId']! as String;
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.syncBegin,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-items',
        sequence: 1,
        requestId: subscriptionId,
        catalogState: 'catalog-items',
        statusState: 'status-items',
      ),
    );
    await gateway.nextOutgoing('conversation_sync_ack');

    final load = service.loadToolDetails(
      provider: 'codex',
      providerSessionId: 'thread-items',
      gap: const HistoryToolDetailGap(
        gapId: 'gap-items',
        toolUseIds: ['tool-1'],
        toolNames: ['Read'],
        toolCallCount: 1,
        turnId: 'turn-1',
      ),
      toolUseIds: const ['tool-1'],
    );
    final request = await gateway.nextOutgoing('conversation_items_page');
    expect(request['turnId'], 'turn-1');
    expect(request['toolUseIds'], ['tool-1']);
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.itemsPageResponse,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-items',
        sequence: 2,
        requestId: request['requestId']! as String,
        provider: 'codex',
        providerSessionId: 'thread-items',
        turnId: 'turn-1',
        data: const [
          {
            'type': 'history_tool_details',
            'requestId': 'nested-items',
            'sessionId': 'thread-items',
            'details': [
              {
                'toolUseId': 'tool-1',
                'toolName': 'Read',
                'input': {'path': '/tmp/example'},
                'result': {'content': 'loaded'},
              },
            ],
          },
        ],
        nextCursor: null,
      ),
    );

    final details = await load;
    expect(details?.single.toolUseId, 'tool-1');
    expect(details?.single.input, {'path': '/tmp/example'});
    expect(details?.single.result?.content, 'loaded');
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      2,
    );
  });

  test(
    'persists and forwards a read watermark on the active v2 stream',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final subscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final subscriptionId = subscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-read',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-1',
          statusState: 'status-1',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final readAt = DateTime.utc(2026, 7, 30, 1, 2, 3);
      await service.markConversationRead(
        provider: 'codex',
        providerSessionId: 'thread-read',
        readAt: readAt,
      );

      final outgoing = await gateway.nextOutgoing('conversation_sync_read');
      expect(outgoing['providerSessionId'], 'thread-read');
      expect(outgoing['readAt'], readAt.toIso8601String());
      final stored = await repository.loadReadWatermarks(
        SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      );
      expect(stored.single.providerSessionId, 'thread-read');
      expect(stored.single.readAt, readAt.toIso8601String());
    },
  );

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
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket',
      ),
      provider: 'codex',
      providerSessionId: 'thread-1',
    );
    expect(cached?.revision, 'revision-1');
    expect(cached?.entries.single.entryId, 'entry-1');
    expect(
      await repository.loadConversationWindow(
        target: SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-b',
        ),
        provider: 'codex',
        providerSessionId: 'thread-1',
      ),
      isNull,
    );
  });

  test('isolates hot windows by Codex source on the same Bridge', () async {
    gateway.codexSourceId = 'codex-home-a';
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
        providerSessionId: 'thread-shared-id',
        revision: 'revision-home-a',
        entryCount: 1,
        pageCount: 1,
        hasEarlier: false,
        sourceEntryCount: 1,
      ),
    );
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.snapshotPage,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-shared-id',
        revision: 'revision-home-a',
        pageIndex: 0,
        pageCount: 1,
        entries: [_wireEntry('entry-home-a', 0)],
      ),
    );
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.snapshotComplete,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-shared-id',
        revision: 'revision-home-a',
        entryCount: 1,
        hasEarlier: false,
        sourceEntryCount: 1,
      ),
    );
    await gateway.nextOutgoing('conversation_content_ack');

    final homeA = await service.loadCachedWindow(
      provider: 'codex',
      providerSessionId: 'thread-shared-id',
    );
    expect(homeA?.revision, 'revision-home-a');
    expect(homeA?.entries.single.entryId, 'entry-home-a');

    gateway.codexSourceId = 'codex-home-b';
    expect(
      await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-shared-id',
      ),
      isNull,
    );

    gateway.codexSourceId = 'codex-home-a';
    final restoredHomeA = await service.loadCachedWindow(
      provider: 'codex',
      providerSessionId: 'thread-shared-id',
    );
    expect(restoredHomeA?.revision, 'revision-home-a');
    expect(restoredHomeA?.entries.single.entryId, 'entry-home-a');
  });

  test('resubscribes when the Codex source changes on one Bridge', () async {
    final firstSubscribe = await gateway.nextOutgoing(
      'conversation_content_subscribe',
    );
    firstSubscribe['_observed'] = true;
    final firstSubscriptionId = firstSubscribe['requestId']! as String;
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.subscribed,
        subscriptionId: firstSubscriptionId,
        bridgeInstanceId: 'bridge-1',
        requestId: firstSubscriptionId,
        hotConversationLimit: 10,
      ),
    );

    gateway.codexSourceId = 'codex-home-b';
    gateway.addSessionList();
    final unsubscribe = await gateway.nextOutgoing(
      'conversation_content_unsubscribe',
    );
    expect(unsubscribe['subscriptionId'], firstSubscriptionId);
    final secondSubscribe = await gateway.nextOutgoing(
      'conversation_content_subscribe',
    );
    final secondSubscriptionId = secondSubscribe['requestId']! as String;
    expect(secondSubscriptionId, isNot(firstSubscriptionId));

    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.patch,
        subscriptionId: firstSubscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-old-source',
        baseRevision: 'revision-a',
        revision: 'revision-b',
        entries: [_wireEntry('late-old-source-entry', 1)],
        hasEarlier: false,
        sourceEntryCount: 2,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      await repository.knownConversationRevisions(
        SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-b',
        ),
      ),
      isEmpty,
    );
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
        SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      ),
      isEmpty,
    );
  });

  test('invalid snapshot backs off before resubscribing', () async {
    final initialSubscribe = await gateway.nextOutgoing(
      'conversation_content_subscribe',
    );
    initialSubscribe['_observed'] = true;
    await service.dispose();
    service = ConversationContentSyncService(
      bridge: gateway,
      cache: repository,
      retryBaseDelay: const Duration(milliseconds: 40),
      retryMaxDelay: const Duration(milliseconds: 80),
    )..start(initialLifecycleState: AppLifecycleState.resumed);
    final subscribe = await gateway.nextOutgoing(
      'conversation_content_subscribe',
    );
    final subscriptionId = subscribe['requestId']! as String;
    final subscribeCountBeforeFailure = gateway.sentTypes
        .where((type) => type == 'conversation_content_subscribe')
        .length;
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
        providerSessionId: 'thread-bad',
        revision: 'revision-bad',
        entryCount: 1,
        pageCount: 1,
        hasEarlier: false,
        sourceEntryCount: 1,
      ),
    );
    gateway.addEvent(
      ConversationContentEventMessage(
        event: ConversationContentEventKind.snapshotComplete,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        provider: 'codex',
        providerSessionId: 'thread-bad',
        revision: 'revision-bad',
        entryCount: 1,
        hasEarlier: false,
        sourceEntryCount: 1,
      ),
    );

    await gateway.nextOutgoing('conversation_content_unsubscribe');
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(
      gateway.sentTypes
          .where((type) => type == 'conversation_content_subscribe')
          .length,
      subscribeCountBeforeFailure,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      gateway.sentTypes
          .where((type) => type == 'conversation_content_subscribe')
          .length,
      subscribeCountBeforeFailure + 1,
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

ConversationSyncV2EventMessage _catalogRecoveryEvent({
  required String subscriptionId,
  required String batchId,
  required int sequence,
  required String catalogState,
}) {
  return ConversationSyncV2EventMessage(
    event: ConversationSyncV2EventKind.catalogChanges,
    subscriptionId: subscriptionId,
    bridgeInstanceId: 'bridge-1',
    codexSourceId: 'codex-home-a',
    batchId: batchId,
    sequence: sequence,
    catalogState: catalogState,
    pageIndex: 0,
    pageCount: 1,
    created: [
      ConversationSyncV2CatalogEntry(
        provider: 'codex',
        providerSessionId: 'thread-recovery',
        revision: 'revision-$catalogState',
        projectPath: '/workspace/recovery',
        name: 'Recovery thread',
        createdAt: '2026-07-30T00:00:00.000Z',
        modifiedAt: '2026-07-30T00:01:00.000Z',
        recencyAt: '2026-07-30T00:02:00.000Z',
        availability: 'durable',
      ),
    ],
  );
}

class _FailingCatalogRepository extends SessionCatalogCacheRepository {
  _FailingCatalogRepository(super.database);

  int catalogFailuresRemaining = 0;
  int clearTargetCalls = 0;

  @override
  Future<void> applyConversationCatalogPage({
    required SessionCatalogCacheTarget target,
    required String codexSourceId,
    required String catalogState,
    required int pageIndex,
    required int pageCount,
    required List<ConversationSyncV2CatalogEntry> created,
    required List<ConversationSyncV2CatalogEntry> updated,
    required List<ConversationSyncV2Target> destroyed,
  }) {
    if (catalogFailuresRemaining > 0) {
      catalogFailuresRemaining -= 1;
      return Future<void>.error(StateError('injected catalog failure'));
    }
    return super.applyConversationCatalogPage(
      target: target,
      codexSourceId: codexSourceId,
      catalogState: catalogState,
      pageIndex: pageIndex,
      pageCount: pageCount,
      created: created,
      updated: updated,
      destroyed: destroyed,
    );
  }

  @override
  Future<void> clearTarget(SessionCatalogCacheTarget target) {
    clearTargetCalls += 1;
    return super.clearTarget(target);
  }
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
  String? codexSourceId = 'codex-home-a';

  @override
  String? logicalConnectionIdentity = 'machine:1';

  @override
  String? lastUrl = 'wss://bridge.example/socket?token=secret';

  @override
  bool supportsConversationContentEvents = true;

  @override
  bool supportsConversationSyncV2 = false;

  @override
  bool supportsConversationItemsById = true;

  @override
  BridgeClientDeliveryMode desiredClientDeliveryMode =
      BridgeClientDeliveryMode.interactive;

  @override
  void send(ClientMessage message) {
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    sent.add(json);
    _outgoing.add(json);
  }

  void addEvent(LocalFeatureServerMessage message) {
    _messages.add(message);
  }

  void addSessionList() {
    _sessions.add(const []);
  }

  Future<Map<String, dynamic>> nextOutgoing(String type) async {
    for (final message in sent) {
      if (message['type'] == type && message['_observed'] != true) {
        message['_observed'] = true;
        return message;
      }
    }
    final message = await _outgoing.stream.firstWhere(
      (message) => message['type'] == type,
    );
    message['_observed'] = true;
    return message;
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
