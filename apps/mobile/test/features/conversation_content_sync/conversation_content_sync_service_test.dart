import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
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
    final syncUpdates = <ConversationSyncCacheUpdate>[];
    final syncUpdatesSubscription = service.syncUpdates.listen(syncUpdates.add);
    addTearDown(syncUpdatesSubscription.cancel);

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
    await pumpEventQueue();
    final catalogUpdate = syncUpdates.singleWhere(
      (update) => update.kind == ConversationSyncCacheUpdateKind.catalog,
    );
    expect(catalogUpdate.targetFingerprint, isNotEmpty);
    final catalogTargetFingerprint = catalogUpdate.targetFingerprint!;
    expect(catalogUpdate.codexSourceId, 'codex-home-a');
    expect(catalogUpdate.catalogUpserts.single.providerSessionId, 'thread-v2');
    expect(catalogUpdate.catalogDestroyed, isEmpty);

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
    expect(
      service.cacheCommitEpochFor(
        targetFingerprint: catalogTargetFingerprint,
        provider: 'codex',
        providerSessionId: 'thread-v2',
      ),
      0,
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
        entries: [
          _assistantWireEntry(
            'entry-2',
            1,
            receivedAt: '2026-07-30T00:03:00.000Z',
          ),
        ],
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
    expect(
      service.cacheCommitEpochFor(
        targetFingerprint: catalogTargetFingerprint,
        provider: 'codex',
        providerSessionId: 'thread-v2',
      ),
      1,
    );
    expect(
      service.cacheCommitEpochFor(
        targetFingerprint: catalogTargetFingerprint,
        provider: 'codex',
        providerSessionId: 'unrelated-thread',
      ),
      0,
    );
    await pumpEventQueue();
    expect(
      syncUpdates
          .where(
            (update) =>
                update.kind == ConversationSyncCacheUpdateKind.timeline &&
                update.providerSessionId == 'thread-v2',
          )
          .last
          .lastAssistantOutputAt,
      '2026-07-30T00:03:00.000Z',
    );

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
    'rejects a runtime overlay before sync_begin establishes authority',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
      )..start(initialLifecycleState: AppLifecycleState.resumed);
      final overlays = <ConversationSyncV2EventMessage>[];
      final overlaySubscription = service.runtimeOverlays.listen(overlays.add);
      addTearDown(overlaySubscription.cancel);

      final subscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final pendingSubscriptionId = subscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.runtimeOverlay,
          subscriptionId: pendingSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-overlay-before-begin',
          sequence: 1,
          provider: 'codex',
          providerSessionId: 'thread-overlay',
          overlayId: 'overlay-before-begin',
          observedAt: '2026-08-10T00:59:59.000Z',
          originGeneration: 'observer:1:1',
          authorityGeneration: 'daemon:1',
          turnId: 'turn-a',
          overlayMessage: const ErrorMessage(message: 'out of order warning'),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_unsubscribe');
      await pumpEventQueue();
      expect(overlays, isEmpty);
    },
  );

  test('forwards only current ordered runtime overlays', () async {
    await service.dispose();
    gateway.supportsConversationSyncV2 = true;
    service = ConversationContentSyncService(bridge: gateway, cache: repository)
      ..start(initialLifecycleState: AppLifecycleState.resumed);
    final overlays = <ConversationSyncV2EventMessage>[];
    final overlaySubscription = service.runtimeOverlays.listen(overlays.add);
    addTearDown(overlaySubscription.cancel);

    final firstSubscribe = await gateway.nextOutgoing(
      'conversation_sync_subscribe',
    );
    final firstSubscriptionId = firstSubscribe['requestId']! as String;
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.syncBegin,
        subscriptionId: firstSubscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-overlay-1',
        sequence: 1,
        requestId: firstSubscriptionId,
        catalogState: 'catalog-overlay',
        statusState: 'status-overlay',
      ),
    );
    await gateway.nextOutgoing('conversation_sync_ack');
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.runtimeOverlay,
        subscriptionId: firstSubscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-overlay-1',
        sequence: 2,
        provider: 'codex',
        providerSessionId: 'thread-overlay',
        overlayId: 'overlay-current-1',
        observedAt: '2026-08-10T01:00:00.000Z',
        originGeneration: 'observer:1:1',
        authorityGeneration: 'daemon:1',
        turnId: 'turn-a',
        overlayMessage: ErrorMessage(message: 'first warning'),
      ),
    );
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      2,
    );
    await pumpEventQueue();
    expect(overlays.map((event) => event.overlayId), ['overlay-current-1']);

    expect(service.retryBootstrap(reason: 'overlay_test'), isTrue);
    await gateway.nextOutgoing('conversation_sync_unsubscribe');
    final secondSubscribe = await gateway.nextOutgoing(
      'conversation_sync_subscribe',
    );
    final secondSubscriptionId = secondSubscribe['requestId']! as String;

    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.runtimeOverlay,
        subscriptionId: firstSubscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-overlay-1',
        sequence: 3,
        provider: 'codex',
        providerSessionId: 'thread-overlay',
        overlayId: 'overlay-stale',
        observedAt: '2026-08-10T01:00:01.000Z',
        originGeneration: 'observer:1:1',
        authorityGeneration: 'daemon:1',
        turnId: 'turn-a',
        overlayMessage: ErrorMessage(message: 'stale warning'),
      ),
    );
    await pumpEventQueue();
    expect(overlays.map((event) => event.overlayId), ['overlay-current-1']);

    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.syncBegin,
        subscriptionId: secondSubscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-overlay-2',
        sequence: 1,
        requestId: secondSubscriptionId,
        catalogState: 'catalog-overlay',
        statusState: 'status-overlay',
      ),
    );
    await gateway.nextOutgoing('conversation_sync_ack');
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.runtimeOverlay,
        subscriptionId: secondSubscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-overlay-2',
        sequence: 2,
        provider: 'codex',
        providerSessionId: 'thread-overlay',
        overlayId: 'overlay-current-2',
        observedAt: '2026-08-10T01:00:02.000Z',
        originGeneration: 'observer:1:2',
        authorityGeneration: 'daemon:1',
        turnId: 'turn-a',
        overlayMessage: ErrorMessage(message: 'second warning'),
      ),
    );
    expect(
      (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
      2,
    );
    await pumpEventQueue();
    expect(overlays.map((event) => event.overlayId), [
      'overlay-current-1',
      'overlay-current-2',
    ]);
  });

  test(
    'retry revokes live readiness before the replacement subscribe can fail',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
      );
      final updates = <ConversationSyncCacheUpdate>[];
      final updatesSubscription = service.syncUpdates.listen(updates.add);
      addTearDown(updatesSubscription.cancel);
      service.start(initialLifecycleState: AppLifecycleState.resumed);

      final firstSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final firstSubscriptionId = firstSubscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-retry-ready',
          sequence: 1,
          requestId: firstSubscriptionId,
          catalogState: 'catalog-retry-ready',
          statusState: 'status-retry-ready',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncCheckpoint,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-retry-ready',
          sequence: 2,
          phase: 'priority',
          hasMore: true,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      await pumpEventQueue();
      expect(
        updates.where(
          (update) =>
              update.kind == ConversationSyncCacheUpdateKind.priorityReady,
        ),
        isNotEmpty,
      );

      updates.clear();
      expect(service.retryBootstrap(reason: 'test_retry'), isTrue);
      await pumpEventQueue();
      expect(updates.single.kind, ConversationSyncCacheUpdateKind.started);
      await gateway.nextOutgoing('conversation_sync_unsubscribe');
      await gateway.nextOutgoing('conversation_sync_subscribe');
      expect(
        updates.where(
          (update) =>
              update.kind == ConversationSyncCacheUpdateKind.priorityReady,
        ),
        isEmpty,
      );
    },
  );

  test(
    'publishes catalog and status only after the complete logical batch commits',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket?token=secret',
      );
      await repository.applyConversationCatalogPage(
        target: target,
        codexSourceId: 'codex-home-a',
        catalogState: 'catalog-old',
        pageIndex: 0,
        pageCount: 1,
        created: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-existing',
            revision: 'revision-old',
            projectPath: '/workspace/existing',
            name: 'Existing thread',
            createdAt: '2026-07-30T00:00:00.000Z',
            modifiedAt: '2026-07-30T00:01:00.000Z',
            recencyAt: '2026-07-30T00:01:00.000Z',
            availability: 'durable',
          ),
        ],
        updated: const [],
        destroyed: const [],
      );

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
          batchId: 'batch-atomic',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-new',
          statusState: 'status-new',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.catalogChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-atomic',
          sequence: 2,
          catalogState: 'catalog-new',
          pageIndex: 0,
          pageCount: 2,
          updated: const [
            ConversationSyncV2CatalogEntry(
              provider: 'codex',
              providerSessionId: 'thread-existing',
              revision: 'revision-new',
              projectPath: '/workspace/existing',
              name: 'Updated thread',
              createdAt: '2026-07-30T00:00:00.000Z',
              modifiedAt: '2026-07-30T00:02:00.000Z',
              recencyAt: '2026-07-30T00:02:00.000Z',
              availability: 'durable',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      expect(
        (await repository.load(target))?.sessions.single.name,
        'Existing thread',
      );
      expect(
        updates.where(
          (update) => update.kind == ConversationSyncCacheUpdateKind.catalog,
        ),
        isEmpty,
      );

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.catalogChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-atomic',
          sequence: 3,
          catalogState: 'catalog-new',
          pageIndex: 1,
          pageCount: 2,
          created: const [
            ConversationSyncV2CatalogEntry(
              provider: 'codex',
              providerSessionId: 'thread-created',
              revision: 'revision-created',
              projectPath: '/workspace/created',
              name: 'Created thread',
              createdAt: '2026-07-30T00:00:00.000Z',
              modifiedAt: '2026-07-30T00:03:00.000Z',
              recencyAt: '2026-07-30T00:03:00.000Z',
              availability: 'durable',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      final catalog = await repository.load(target);
      expect(catalog?.sessions.map((session) => session.name), [
        'Created thread',
        'Updated thread',
      ]);
      final catalogUpdates = updates
          .where(
            (update) => update.kind == ConversationSyncCacheUpdateKind.catalog,
          )
          .toList(growable: false);
      expect(catalogUpdates, hasLength(1));
      expect(catalogUpdates.single.catalogUpserts, hasLength(2));
      expect(catalogUpdates.single.pageIndex, 1);
      expect(catalogUpdates.single.pageCount, 2);

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-atomic',
          sequence: 4,
          statusState: 'status-new',
          pageIndex: 0,
          pageCount: 2,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-existing',
              activity: 'working',
              attention: 'none',
              result: 'none',
              runtimeAttachment: 'loaded',
              source: 'appServer',
              confidence: 'authoritative',
              observedAt: '2026-07-30T00:04:00.000Z',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      expect(await repository.loadConversationStatuses(target), isEmpty);
      expect(
        updates.where(
          (update) => update.kind == ConversationSyncCacheUpdateKind.status,
        ),
        isEmpty,
      );

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-atomic',
          sequence: 5,
          statusState: 'status-new',
          pageIndex: 1,
          pageCount: 2,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-created',
              activity: 'idle',
              attention: 'question',
              result: 'none',
              runtimeAttachment: 'notLoaded',
              source: 'appServer',
              confidence: 'authoritative',
              observedAt: '2026-07-30T00:04:01.000Z',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      expect(await repository.loadConversationStatuses(target), hasLength(2));
      final statusUpdates = updates
          .where(
            (update) => update.kind == ConversationSyncCacheUpdateKind.status,
          )
          .toList(growable: false);
      expect(statusUpdates, hasLength(1));
      expect(statusUpdates.single.statusChanges, hasLength(2));
      expect(statusUpdates.single.pageIndex, 1);
      expect(statusUpdates.single.pageCount, 2);
    },
  );

  test(
    'missing logical pages restart without exposing a mixed catalog snapshot',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket?token=secret',
      );
      await repository.applyConversationCatalogPage(
        target: target,
        codexSourceId: 'codex-home-a',
        catalogState: 'catalog-old',
        pageIndex: 0,
        pageCount: 1,
        created: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-stable',
            revision: 'revision-stable',
            projectPath: '/workspace/stable',
            name: 'Stable thread',
            createdAt: '2026-07-30T00:00:00.000Z',
            modifiedAt: '2026-07-30T00:01:00.000Z',
            recencyAt: '2026-07-30T00:01:00.000Z',
            availability: 'durable',
          ),
        ],
        updated: const [],
        destroyed: const [],
      );

      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
        retryBaseDelay: const Duration(milliseconds: 40),
        retryMaxDelay: const Duration(milliseconds: 80),
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
          batchId: 'batch-incomplete',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-new',
          statusState: 'status-new',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.catalogChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-incomplete',
          sequence: 2,
          catalogState: 'catalog-new',
          pageIndex: 0,
          pageCount: 2,
          updated: const [
            ConversationSyncV2CatalogEntry(
              provider: 'codex',
              providerSessionId: 'thread-stable',
              revision: 'revision-uncommitted',
              projectPath: '/workspace/stable',
              name: 'Uncommitted thread',
              createdAt: '2026-07-30T00:00:00.000Z',
              modifiedAt: '2026-07-30T00:02:00.000Z',
              recencyAt: '2026-07-30T00:02:00.000Z',
              availability: 'durable',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncCheckpoint,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-incomplete',
          sequence: 3,
          phase: 'priority',
          hasMore: true,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_unsubscribe');

      expect(
        (await repository.load(target))?.sessions.single.name,
        'Stable thread',
      );
      expect(
        updates.where(
          (update) => update.kind == ConversationSyncCacheUpdateKind.catalog,
        ),
        isEmpty,
      );
    },
  );

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
      await service.markConversationRead(
        provider: 'codex',
        providerSessionId: 'thread-active',
        readAt: DateTime.utc(2026, 7, 30, 2),
      );
      await gateway.nextOutgoing('conversation_sync_read');
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
    'base revision mismatch retries one thread as a snapshot without blanking cache',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationWindowCoverage = true;
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket?token=secret',
      );
      await repository.replaceConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-mismatch',
        revision: 'revision-local',
        entries: [_wireEntry('entry-local', 0)],
        hasEarlier: true,
        sourceEntryCount: 1,
      );
      await repository.replaceConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-unaffected',
        revision: 'revision-unaffected',
        entries: [_wireEntry('entry-unaffected', 0)],
        hasEarlier: true,
        sourceEntryCount: 1,
      );
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
        retryBaseDelay: const Duration(milliseconds: 1),
        retryMaxDelay: const Duration(milliseconds: 1),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final firstSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      expect(
        firstSubscribe['threadContentStates'],
        contains(containsPair('providerSessionId', 'thread-mismatch')),
      );
      final firstSubscriptionId = firstSubscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-mismatch-1',
          sequence: 1,
          requestId: firstSubscriptionId,
          catalogState: 'catalog-mismatch',
          statusState: 'status-mismatch',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-mismatch-1',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-mismatch',
          revision: 'revision-next',
          baseRevision: 'revision-bridge-base',
          mode: 'patch',
          phase: 'priority',
          timelineIndex: 0,
          timelineCount: 1,
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('entry-next', 1)],
          hasEarlier: true,
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_unsubscribe');

      final retained = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-mismatch',
      );
      expect(retained?.revision, 'revision-local');
      expect(retained?.entries.single.entryId, 'entry-local');

      final secondSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      expect(
        (secondSubscribe['threadContentStates'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere(
              (state) => state['providerSessionId'] == 'thread-mismatch',
            ),
        containsPair('forceReplacement', true),
      );
      expect(
        secondSubscribe['threadContentStates'],
        contains(containsPair('providerSessionId', 'thread-unaffected')),
      );
      final unaffected = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-unaffected',
      );
      expect(unaffected?.revision, 'revision-unaffected');
      expect(unaffected?.entries.single.entryId, 'entry-unaffected');
      final secondSubscriptionId = secondSubscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-mismatch-2',
          sequence: 1,
          requestId: secondSubscriptionId,
          catalogState: 'catalog-mismatch',
          statusState: 'status-mismatch',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-mismatch-2',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-mismatch',
          revision: 'revision-next',
          mode: 'snapshot',
          phase: 'priority',
          timelineIndex: 0,
          timelineCount: 1,
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('entry-next', 0)],
          hasEarlier: true,
          windowComplete: true,
          sourceEntryCount: 1,
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        2,
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncCheckpoint,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-mismatch-2',
          sequence: 3,
          phase: 'priority',
          hasMore: false,
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        3,
      );

      final repaired = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-mismatch',
      );
      expect(repaired?.revision, 'revision-next');
      expect(repaired?.entries.single.entryId, 'entry-next');
      expect(
        gateway.sentTypes
            .where((type) => type == 'conversation_sync_unsubscribe')
            .length,
        1,
      );
    },
  );

  test(
    'old v2 Bridge never receives the additive forceReplacement field',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationWindowCoverage = false;
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket?token=secret',
      );
      await repository.replaceConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-old-v2',
        revision: 'revision-old-v2',
        entries: [_wireEntry('entry-old-v2', 0)],
        hasEarlier: true,
        windowComplete: false,
        latestTurnComplete: false,
        latestTurnGap: const ConversationSyncV2LatestTurnGap(
          missingEntryCount: 1,
          payloadOmitted: false,
          repair: 'turns_page',
        ),
        sourceEntryCount: 2,
      );
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final subscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final state = (subscribe['threadContentStates'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (candidate) => candidate['providerSessionId'] == 'thread-old-v2',
          );
      expect(state['revision'], 'revision-old-v2');
      expect(state.containsKey('forceReplacement'), isFalse);

      final subscriptionId = subscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-old-v2',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-old-v2',
          statusState: 'status-old-v2',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-old-v2',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-old-v2',
          revision: 'revision-old-v2-next',
          baseRevision: 'revision-old-v2',
          mode: 'patch',
          phase: 'priority',
          timelineIndex: 0,
          timelineCount: 1,
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('entry-old-v2-next', 1)],
          deletes: const ['entry-old-v2'],
          hasEarlier: true,
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            missingEntryCount: 1,
            payloadOmitted: false,
            repair: 'turns_page',
          ),
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      final retained = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-old-v2',
      );
      expect(retained?.revision, 'revision-old-v2-next');
      expect(retained?.windowComplete, isFalse);
      expect(retained?.entries.map((entry) => entry.entryId), [
        'entry-old-v2',
        'entry-old-v2-next',
      ]);

      expect(service.retryBootstrap(reason: 'old_v2_lineage_test'), isTrue);
      await gateway.nextOutgoing('conversation_sync_unsubscribe');
      final retry = await gateway.nextOutgoing('conversation_sync_subscribe');
      final retriedState = (retry['threadContentStates'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (candidate) => candidate['providerSessionId'] == 'thread-old-v2',
          );
      expect(retriedState['revision'], 'revision-old-v2-next');
      expect(retriedState.containsKey('forceReplacement'), isFalse);
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
    'thread reset advances only its cache fence and publishes a reread',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        logicalConnectionIdentity: 'machine:1',
        websocketUrl: 'wss://bridge.example/socket',
      );
      await repository.replaceConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-reset-fence',
        revision: 'revision-before-reset',
        entries: [_wireEntry('entry-before-reset', 0)],
        hasEarlier: true,
        sourceEntryCount: 12,
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
      final subscriptionId = subscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-thread-reset-fence',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-reset-fence',
          statusState: 'status-reset-fence',
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        1,
      );

      final beforeEpoch = service.cacheCommitEpochFor(
        targetFingerprint: target.fingerprint,
        provider: 'codex',
        providerSessionId: 'thread-reset-fence',
      );
      final unrelatedBefore = service.cacheCommitEpochFor(
        targetFingerprint: target.fingerprint,
        provider: 'codex',
        providerSessionId: 'thread-unrelated',
      );
      final invalidation = service.updates.firstWhere(
        (update) => update.providerSessionId == 'thread-reset-fence',
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncReset,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-thread-reset-fence',
          sequence: 2,
          scope: 'thread',
          reason: 'base_revision_mismatch',
          target: const ConversationSyncV2Target(
            provider: 'codex',
            providerSessionId: 'thread-reset-fence',
          ),
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        2,
      );
      expect((await invalidation).revision, startsWith('invalidated:'));
      expect(
        service.cacheCommitEpochFor(
          targetFingerprint: target.fingerprint,
          provider: 'codex',
          providerSessionId: 'thread-reset-fence',
        ),
        greaterThan(beforeEpoch),
      );
      expect(
        service.cacheCommitEpochFor(
          targetFingerprint: target.fingerprint,
          provider: 'codex',
          providerSessionId: 'thread-unrelated',
        ),
        unrelatedBefore,
      );
      final retained = await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-reset-fence',
      );
      expect(retained?.revision, 'revision-before-reset');
      expect(retained?.entries.single.entryId, 'entry-before-reset');
    },
  );

  test(
    'preserves readable cache and retry backoff after partial progress',
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
        allowUnanchoredLegacySeed: true,
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
      expect(failingRepository.clearTargetCalls, 0);

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
      final secondRetryDelay = Stopwatch()..start();
      await gateway.nextOutgoing('conversation_sync_unsubscribe');
      expect(failingRepository.clearTargetCalls, 0);

      final subscribeCount = gateway.sentTypes
          .where((type) => type == 'conversation_sync_subscribe')
          .length;
      await gateway.nextOutgoing('conversation_sync_subscribe');
      secondRetryDelay.stop();
      expect(
        gateway.sentTypes
            .where((type) => type == 'conversation_sync_subscribe')
            .length,
        subscribeCount + 1,
      );
      expect(
        secondRetryDelay.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 70)),
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

  test(
    'loads and reuses a lightweight user index without tool payloads',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationUserIndex = true;
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
          batchId: 'batch-user-index',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-user-index',
          statusState: 'status-user-index',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.loadUserMessageIndex(
        provider: 'codex',
        providerSessionId: 'thread-user-index',
        revision: 'revision-user-index',
      );
      final request = await gateway.nextOutgoing('conversation_turns_page');
      expect(request['projection'], 'user_index');
      expect(request['itemsView'], 'summary');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-user-index',
          sequence: 2,
          requestId: request['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-user-index',
          data: const [
            {
              'turnId': 'turn-user-index',
              'messages': [
                {
                  'type': 'user_input',
                  'text': 'indexed prompt',
                  'providerItemId': 'provider-user-index',
                  'timestamp': '2026-08-08T01:02:03.000Z',
                },
              ],
              'itemCount': 1,
              'itemsView': 'summary',
            },
          ],
          nextCursor: null,
        ),
      );

      final snapshot = await load;
      expect(snapshot?.complete, isTrue);
      expect(snapshot?.entries.single.providerTurnId, 'turn-user-index');
      expect(snapshot?.entries.single.providerItemId, 'provider-user-index');
      expect(snapshot?.entries.single.message.text, 'indexed prompt');
      await gateway.nextOutgoing('conversation_sync_ack');
      final requestsBeforeCacheHit = gateway.sentTypes
          .where((type) => type == 'conversation_turns_page')
          .length;
      final cacheHit = await service.loadUserMessageIndex(
        provider: 'codex',
        providerSessionId: 'thread-user-index',
        revision: 'revision-user-index',
      );
      expect(cacheHit?.entries.single.message.text, 'indexed prompt');
      expect(
        gateway.sentTypes
            .where((type) => type == 'conversation_turns_page')
            .length,
        requestsBeforeCacheHit,
      );
    },
  );

  test(
    'stops a lightweight user index when the provider repeats a cursor',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationUserIndex = true;
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
          batchId: 'batch-user-index-loop',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-user-index-loop',
          statusState: 'status-user-index-loop',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.loadUserMessageIndex(
        provider: 'codex',
        providerSessionId: 'thread-user-index-loop',
        revision: 'revision-user-index-loop',
      );
      final firstRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-user-index-loop',
          sequence: 2,
          requestId: firstRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-user-index-loop',
          data: const [],
          nextCursor: 'cursor-loop',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final secondRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      expect(secondRequest['cursor'], 'cursor-loop');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-user-index-loop',
          sequence: 3,
          requestId: secondRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-user-index-loop',
          data: const [],
          nextCursor: 'cursor-loop',
        ),
      );

      await expectLater(
        load,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('repeated cursor'),
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      expect(
        gateway.sentTypes
            .where((type) => type == 'conversation_turns_page')
            .length,
        2,
      );
    },
  );

  test(
    'loads one provider turn by bounded item pages then serves SQLite',
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
          batchId: 'batch-user-turn',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-user-turn',
          statusState: 'status-user-turn',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.loadUserTurnWindow(
        provider: 'codex',
        providerSessionId: 'thread-user-turn',
        providerTurnId: 'turn-target',
        revision: 'revision-user-turn',
      );
      final firstRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(firstRequest['turnId'], 'turn-target');
      expect(firstRequest['cursor'], isNull);
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-user-turn',
          sequence: 2,
          requestId: firstRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-user-turn',
          turnId: 'turn-target',
          data: const [
            {
              'type': 'user_input',
              'text': 'target prompt',
              'providerItemId': 'provider-target-user',
            },
          ],
          nextCursor: 'target-page-2',
        ),
      );
      final secondRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(secondRequest['cursor'], 'target-page-2');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-user-turn',
          sequence: 3,
          requestId: secondRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-user-turn',
          turnId: 'turn-target',
          data: const [
            {
              'type': 'assistant',
              'message': {
                'id': 'assistant-target',
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'target answer'},
                ],
              },
            },
          ],
          nextCursor: null,
        ),
      );

      final messages = await load;
      expect(messages, hasLength(2));
      expect(
        (messages?.first as UserInputMessage).historyTurnId,
        'turn-target',
      );
      expect(
        (messages?.last as AssistantServerMessage).historyTurnId,
        'turn-target',
      );
      final requestsBeforeCacheHit = gateway.sentTypes
          .where((type) => type == 'conversation_items_page')
          .length;
      final refresh = service.loadUserTurnWindow(
        provider: 'codex',
        providerSessionId: 'thread-user-turn',
        providerTurnId: 'turn-target',
        revision: 'newer-revision',
      );
      final refreshRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(
        gateway.sentTypes
            .where((type) => type == 'conversation_items_page')
            .length,
        requestsBeforeCacheHit + 1,
      );
      expect(
        (await repository.loadConversationUserTurnDetail(
          target: SessionCatalogCacheTarget.fromBridge(
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'codex-home-a',
          ),
          provider: 'codex',
          providerSessionId: 'thread-user-turn',
          providerTurnId: 'turn-target',
        ))?.revision,
        'revision-user-turn',
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-user-turn',
          sequence: 4,
          requestId: refreshRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-user-turn',
          turnId: 'turn-target',
          data: const [
            {
              'type': 'user_input',
              'text': 'updated prompt',
              'providerItemId': 'provider-target-user-new',
            },
          ],
          nextCursor: null,
        ),
      );
      final refreshed = await refresh;
      expect(refreshed, hasLength(1));
      expect((refreshed?.single as UserInputMessage).text, 'updated prompt');
      expect(
        (await repository.loadConversationUserTurnDetail(
          target: SessionCatalogCacheTarget.fromBridge(
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'codex-home-a',
          ),
          provider: 'codex',
          providerSessionId: 'thread-user-turn',
          providerTurnId: 'turn-target',
        ))?.revision,
        'newer-revision',
      );
    },
  );

  test('separates turn detail flights by content revision', () async {
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
        batchId: 'batch-revision-flights',
        sequence: 1,
        requestId: subscriptionId,
        catalogState: 'catalog-revision-flights',
        statusState: 'status-revision-flights',
      ),
    );
    await gateway.nextOutgoing('conversation_sync_ack');

    final first = service.loadUserTurnWindow(
      provider: 'codex',
      providerSessionId: 'thread-revision-flights',
      providerTurnId: 'turn-revision-flights',
      revision: 'revision-a',
    );
    final firstRequest = await gateway.nextOutgoing('conversation_items_page');
    final second = service.loadUserTurnWindow(
      provider: 'codex',
      providerSessionId: 'thread-revision-flights',
      providerTurnId: 'turn-revision-flights',
      revision: 'revision-b',
    );
    final secondRequest = await gateway
        .nextOutgoing('conversation_items_page')
        .timeout(const Duration(seconds: 2));
    expect(secondRequest['requestId'], isNot(firstRequest['requestId']));

    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.itemsPageResponse,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-revision-flights',
        sequence: 2,
        requestId: firstRequest['requestId']! as String,
        provider: 'codex',
        providerSessionId: 'thread-revision-flights',
        turnId: 'turn-revision-flights',
        data: const [
          {'type': 'user_input', 'text': 'superseded revision'},
        ],
        nextCursor: null,
      ),
    );
    expect(await first, isNull);
    gateway.addEvent(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.itemsPageResponse,
        subscriptionId: subscriptionId,
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
        batchId: 'batch-revision-flights',
        sequence: 3,
        requestId: secondRequest['requestId']! as String,
        provider: 'codex',
        providerSessionId: 'thread-revision-flights',
        turnId: 'turn-revision-flights',
        data: const [
          {'type': 'user_input', 'text': 'current revision'},
        ],
        nextCursor: null,
      ),
    );
    final current = await second;
    expect((current?.single as UserInputMessage).text, 'current revision');
  });

  test(
    'serializes older paging and latest-turn repair without discarding prefix',
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
          batchId: 'batch-incomplete-with-older',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-incomplete-with-older',
          statusState: 'status-incomplete-with-older',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-incomplete-with-older',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-incomplete-with-older',
          revision: 'revision-incomplete-with-older',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('incomplete-latest-shell', 0)],
          hasEarlier: true,
          turnsNextCursor: 'older-while-latest-active',
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            missingEntryCount: 1,
            payloadOmitted: false,
            repair: 'turns_page',
          ),
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final olderLoad = service.loadOlderTurns(
        provider: 'codex',
        providerSessionId: 'thread-incomplete-with-older',
      );
      final repairLoad = service.repairLatestTurn(
        provider: 'codex',
        providerSessionId: 'thread-incomplete-with-older',
      );
      final request = await gateway.nextOutgoing('conversation_turns_page');
      expect(request['cursor'], 'older-while-latest-active');
      await Future<void>.delayed(Duration.zero);
      expect(
        gateway.sentTypes.where((type) => type == 'conversation_turns_page'),
        hasLength(1),
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-incomplete-with-older',
          sequence: 3,
          requestId: request['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-incomplete-with-older',
          data: const [
            {
              'turnId': 'older-turn',
              'messages': [
                {
                  'type': 'user_input',
                  'text': 'Older cached prompt',
                  'userMessageUuid': 'older-cached-user',
                },
              ],
              'itemCount': 1,
              'itemsView': 'summary',
            },
          ],
          nextCursor: null,
        ),
      );

      final olderResult = await olderLoad;
      expect(olderResult.loaded, isTrue);
      expect(olderResult.hasMore, isFalse);
      await gateway.nextOutgoing('conversation_sync_ack');

      final repairRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      expect(repairRequest, isNot(contains('cursor')));
      expect(repairRequest['limit'], 1);
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-incomplete-with-older',
          sequence: 4,
          requestId: repairRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-incomplete-with-older',
          data: const [
            {
              'turnId': 'latest-turn',
              'messages': [
                {
                  'type': 'user_input',
                  'text': 'Latest repaired prompt',
                  'userMessageUuid': 'latest-repaired-user',
                },
              ],
              'itemCount': 1,
              'itemsView': 'summary',
            },
          ],
          nextCursor: 'provider-cursor-before-preserved-prefix',
        ),
      );
      final repairResult = await repairLoad;
      expect(repairResult.loaded, isTrue);
      expect(repairResult.hasMore, isFalse);
      await gateway.nextOutgoing('conversation_sync_ack');

      final cached = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-incomplete-with-older',
      );
      expect(cached?.latestTurnComplete, isFalse);
      expect(cached?.windowComplete, isFalse);
      expect(cached?.hasEarlier, isFalse);
      expect(cached?.turnsNextCursor, isNull);
      expect(cached?.entries.map((entry) => entry.entryId), [
        'user:older-cached-user',
        'incomplete-latest-shell',
        'user:latest-repaired-user',
      ]);
    },
  );

  test(
    'hydrates a multi-page current turn over 512 KiB before older history',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationItemsById = false;
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
          batchId: 'batch-current-gap',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-current-gap',
          statusState: 'status-current-gap',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-current-gap',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-current-gap',
          revision: 'revision-current-gap',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('current-shell', 0)],
          hasEarlier: true,
          turnsNextCursor: 'older-turns-cursor',
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            turnId: 'turn-current',
            missingEntryCount: 2,
            payloadOmitted: true,
            repair: 'items_page',
          ),
          sourceEntryCount: 3,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.repairLatestTurn(
        provider: 'codex',
        providerSessionId: 'thread-current-gap',
      );
      final firstRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(firstRequest['turnId'], 'turn-current');
      expect(firstRequest, isNot(contains('cursor')));
      final firstPayload = 'a' * (300 * 1024);
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-current-gap',
          sequence: 3,
          requestId: firstRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-current-gap',
          turnId: 'turn-current',
          data: [
            {
              'type': 'user_input',
              'text': firstPayload,
              'userMessageUuid': 'current-page-1',
            },
          ],
          nextCursor: 'current-turn-page-2',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      final secondRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(secondRequest['cursor'], 'current-turn-page-2');
      final secondPayload = 'b' * (300 * 1024);
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-current-gap',
          sequence: 4,
          requestId: secondRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-current-gap',
          turnId: 'turn-current',
          data: [
            {
              'type': 'user_input',
              'text': secondPayload,
              'userMessageUuid': 'current-page-2',
            },
          ],
          nextCursor: null,
        ),
      );

      final result = await load;
      expect(result.loaded, isTrue);
      expect(result.hasMore, isTrue);
      final cached = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-current-gap',
      );
      expect(cached?.latestTurnComplete, isTrue);
      expect(cached?.latestTurnGap, isNull);
      expect(cached?.turnsNextCursor, 'older-turns-cursor');
      expect(
        cached?.entries
            .map((entry) => entry.rawMessage['text'])
            .whereType<String>()
            .fold<int>(0, (sum, text) => sum + text.length),
        greaterThan(512 * 1024),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        4,
      );
    },
  );

  test(
    'rejects a terminal projected item without retrying the null cursor',
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
          batchId: 'batch-terminal-item',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-terminal-item',
          statusState: 'status-terminal-item',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-terminal-item',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-terminal-item',
          revision: 'revision-terminal-item',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('terminal-item-shell', 0)],
          hasEarlier: true,
          windowComplete: false,
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            turnId: 'turn-terminal-item',
            missingEntryCount: 1,
            payloadOmitted: true,
            repair: 'items_page',
          ),
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.repairLatestTurn(
        provider: 'codex',
        providerSessionId: 'thread-terminal-item',
      );
      final request = await gateway.nextOutgoing('conversation_items_page');
      final failure = expectLater(
        load,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('frame budget'),
          ),
        ),
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-terminal-item',
          sequence: 3,
          requestId: request['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-terminal-item',
          turnId: 'turn-terminal-item',
          data: const [
            {
              'type': 'assistant',
              'message': {
                'id': 'projected-terminal-item',
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'projected shell'},
                ],
              },
            },
          ],
          nextCursor: null,
          pageComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            turnId: 'turn-terminal-item',
            missingEntryCount: 1,
            payloadOmitted: true,
            repair: 'items_page',
          ),
        ),
      );
      await failure;
      expect(
        gateway.sentTypes.where((type) => type == 'conversation_items_page'),
        hasLength(1),
      );
      final cached = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-terminal-item',
      );
      expect(cached?.entries.map((entry) => entry.entryId), [
        'terminal-item-shell',
      ]);
      expect(cached?.latestTurnComplete, isFalse);
    },
  );

  test(
    'retries latest-turn repair after a sequence gap replaces the subscription',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
        retryBaseDelay: const Duration(milliseconds: 1),
        retryMaxDelay: const Duration(milliseconds: 1),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final firstSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final firstSubscriptionId = firstSubscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-current-gap-retry-1',
          sequence: 1,
          requestId: firstSubscriptionId,
          catalogState: 'catalog-current-gap-retry-1',
          statusState: 'status-current-gap-retry-1',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-current-gap-retry-1',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-current-gap-retry',
          revision: 'revision-current-gap-retry',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('current-gap-retry-shell', 0)],
          hasEarlier: true,
          turnsNextCursor: 'older-current-gap-retry',
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            turnId: 'turn-current-gap-retry',
            missingEntryCount: 1,
            payloadOmitted: true,
            repair: 'items_page',
          ),
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.repairLatestTurn(
        provider: 'codex',
        providerSessionId: 'thread-current-gap-retry',
      );
      final firstRepairRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(firstRepairRequest['subscriptionId'], firstSubscriptionId);
      expect(firstRepairRequest['turnId'], 'turn-current-gap-retry');

      gateway.addEvent(
        _catalogRecoveryEvent(
          subscriptionId: firstSubscriptionId,
          batchId: 'batch-current-gap-retry-1',
          sequence: 4,
          catalogState: 'catalog-current-gap-retry-gap',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_unsubscribe');

      final secondSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final secondSubscriptionId = secondSubscribe['requestId']! as String;
      expect(secondSubscriptionId, isNot(firstSubscriptionId));
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-current-gap-retry-2',
          sequence: 1,
          requestId: secondSubscriptionId,
          catalogState: 'catalog-current-gap-retry-2',
          statusState: 'status-current-gap-retry-2',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final retriedRepairRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(
        retriedRepairRequest['requestId'],
        isNot(firstRepairRequest['requestId']),
      );
      expect(retriedRepairRequest['subscriptionId'], secondSubscriptionId);
      expect(retriedRepairRequest['turnId'], 'turn-current-gap-retry');
      expect(retriedRepairRequest, isNot(contains('cursor')));
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-current-gap-retry-2',
          sequence: 2,
          requestId: retriedRepairRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-current-gap-retry',
          turnId: 'turn-current-gap-retry',
          data: const [
            {
              'type': 'user_input',
              'text': 'Recovered current prompt',
              'userMessageUuid': 'user-current-gap-retry',
            },
          ],
          nextCursor: null,
        ),
      );

      final result = await load;
      expect(result.loaded, isTrue);
      expect(result.hasMore, isTrue);
      final cached = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-current-gap-retry',
      );
      expect(cached?.latestTurnComplete, isTrue);
      expect(cached?.latestTurnGap, isNull);
      expect(cached?.turnsNextCursor, 'older-current-gap-retry');
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        2,
      );
    },
  );

  test(
    'repairs a latest turn with a null cursor before advancing older cursor',
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
          batchId: 'batch-turns-gap',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-turns-gap',
          statusState: 'status-turns-gap',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-turns-gap',
          sequence: 2,
          provider: 'claude',
          providerSessionId: 'thread-turns-gap',
          revision: 'revision-turns-gap',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('incomplete-shell', 0)],
          hasEarlier: true,
          turnsNextCursor: 'older-before-repair',
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            missingEntryCount: 1,
            payloadOmitted: false,
            repair: 'turns_page',
          ),
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final repair = service.repairLatestTurn(
        provider: 'claude',
        providerSessionId: 'thread-turns-gap',
      );
      final repairRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      expect(repairRequest, isNot(contains('cursor')));
      expect(repairRequest['itemsView'], 'full');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-turns-gap',
          sequence: 3,
          requestId: repairRequest['requestId']! as String,
          provider: 'claude',
          providerSessionId: 'thread-turns-gap',
          data: const [
            {
              'turnId': 'latest-turn',
              'messages': [
                {
                  'type': 'user_input',
                  'text': 'Latest complete prompt',
                  'userMessageUuid': 'latest-complete-user',
                },
              ],
              'itemCount': 1,
              'itemsView': 'full',
            },
          ],
          nextCursor: 'older-after-repair',
        ),
      );
      final repairResult = await repair;
      expect(repairResult.loaded, isTrue);
      expect(repairResult.hasMore, isTrue);
      await gateway.nextOutgoing('conversation_sync_ack');

      final older = service.loadOlderTurns(
        provider: 'claude',
        providerSessionId: 'thread-turns-gap',
      );
      final olderRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      expect(olderRequest['cursor'], 'older-after-repair');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-turns-gap',
          sequence: 4,
          requestId: olderRequest['requestId']! as String,
          provider: 'claude',
          providerSessionId: 'thread-turns-gap',
          data: const [],
          nextCursor: null,
        ),
      );
      expect((await older).hasMore, isFalse);
      await gateway.nextOutgoing('conversation_sync_ack');
    },
  );

  test(
    'keeps latest-turn gaps after merge and replace repair failures',
    () async {
      await service.dispose();
      await repository.close();
      final failingRepository = _FailingLatestTurnRepairRepository(
        SessionCatalogCacheDatabase(
          databasePath: path.join(
            temporaryDirectory.path,
            'latest-turn-repair-failure-cache.db',
          ),
          openDatabase: openFfi,
        ),
      );
      repository = failingRepository;
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
          batchId: 'batch-repair-failures',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-repair-failures',
          statusState: 'status-repair-failures',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-repair-failures',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-items-repair-failure',
          revision: 'revision-items-repair-failure',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('items-repair-failure-shell', 0)],
          hasEarlier: true,
          turnsNextCursor: 'older-items-repair-failure',
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            turnId: 'turn-items-repair-failure',
            missingEntryCount: 1,
            payloadOmitted: true,
            repair: 'items_page',
          ),
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-repair-failures',
          sequence: 3,
          provider: 'codex',
          providerSessionId: 'thread-turns-repair-failure',
          revision: 'revision-turns-repair-failure',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('turns-repair-failure-shell', 0)],
          hasEarlier: true,
          turnsNextCursor: 'older-turns-repair-failure',
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            missingEntryCount: 1,
            payloadOmitted: false,
            repair: 'turns_page',
          ),
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final itemsLoad = service.repairLatestTurn(
        provider: 'codex',
        providerSessionId: 'thread-items-repair-failure',
      );
      final itemsFailure = expectLater(
        itemsLoad,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'injected latest-turn merge failure',
          ),
        ),
      );
      final itemsRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-repair-failures',
          sequence: 4,
          requestId: itemsRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-items-repair-failure',
          turnId: 'turn-items-repair-failure',
          data: const [
            {
              'type': 'user_input',
              'text': 'Items repair should fail locally',
              'userMessageUuid': 'user-items-repair-failure',
            },
          ],
          nextCursor: null,
        ),
      );
      await itemsFailure;
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        4,
      );
      final itemsCached = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-items-repair-failure',
      );
      expect(itemsCached?.latestTurnComplete, isFalse);
      expect(itemsCached?.latestTurnGap?.repair, 'items_page');
      expect(failingRepository.clearTargetCalls, 0);

      final turnsLoad = service.repairLatestTurn(
        provider: 'codex',
        providerSessionId: 'thread-turns-repair-failure',
      );
      final turnsFailure = expectLater(
        turnsLoad,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'injected latest-turn replace failure',
          ),
        ),
      );
      final turnsRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      expect(turnsRequest['limit'], 1);
      expect(turnsRequest['itemsView'], 'summary');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-repair-failures',
          sequence: 5,
          requestId: turnsRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-turns-repair-failure',
          data: const [
            {
              'turnId': 'turns-repair-failure',
              'messages': [
                {
                  'type': 'user_input',
                  'text': 'Turns repair should fail locally',
                  'userMessageUuid': 'user-turns-repair-failure',
                },
              ],
              'itemCount': 1,
              'itemsView': 'summary',
            },
          ],
          nextCursor: null,
        ),
      );
      await turnsFailure;
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        5,
      );
      final turnsCached = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-turns-repair-failure',
      );
      expect(turnsCached?.latestTurnComplete, isFalse);
      expect(turnsCached?.latestTurnGap?.repair, 'turns_page');
      expect(failingRepository.clearTargetCalls, 0);
    },
  );

  test(
    'keeps the latest-turn gap when a page exceeds the remaining byte budget',
    () async {
      await service.dispose();
      await repository.close();
      final trackingRepository = _FailingCatalogRepository(
        SessionCatalogCacheDatabase(
          databasePath: path.join(
            temporaryDirectory.path,
            'latest-turn-byte-budget-cache.db',
          ),
          openDatabase: openFfi,
        ),
      );
      repository = trackingRepository;
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
          batchId: 'batch-latest-turn-byte-budget',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-latest-turn-byte-budget',
          statusState: 'status-latest-turn-byte-budget',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-latest-turn-byte-budget',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-latest-turn-byte-budget',
          revision: 'revision-latest-turn-byte-budget',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('latest-turn-byte-budget-shell', 0)],
          hasEarlier: true,
          turnsNextCursor: 'older-latest-turn-byte-budget',
          latestTurnComplete: false,
          latestTurnGap: const ConversationSyncV2LatestTurnGap(
            turnId: 'turn-latest-turn-byte-budget',
            missingEntryCount: 2,
            payloadOmitted: true,
            repair: 'items_page',
          ),
          sourceEntryCount: 3,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.repairLatestTurn(
        provider: 'codex',
        providerSessionId: 'thread-latest-turn-byte-budget',
      );
      final firstRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(firstRequest, isNot(contains('cursor')));
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-latest-turn-byte-budget',
          sequence: 3,
          requestId: firstRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-latest-turn-byte-budget',
          turnId: 'turn-latest-turn-byte-budget',
          data: const [
            {
              'type': 'user_input',
              'text': 'First bounded page',
              'userMessageUuid': 'user-latest-turn-byte-budget-page-1',
            },
          ],
          nextCursor: 'latest-turn-byte-budget-page-2',
        ),
      );
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        3,
      );

      final secondRequest = await gateway.nextOutgoing(
        'conversation_items_page',
      );
      expect(secondRequest['cursor'], 'latest-turn-byte-budget-page-2');
      final failure = expectLater(
        load,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('byte budget'),
          ),
        ),
      );
      final oversizedPayload = 'x' * (8 * 1024 * 1024);
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.itemsPageResponse,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-latest-turn-byte-budget',
          sequence: 4,
          requestId: secondRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-latest-turn-byte-budget',
          turnId: 'turn-latest-turn-byte-budget',
          data: [
            {
              'type': 'user_input',
              'text': oversizedPayload,
              'userMessageUuid': 'user-latest-turn-byte-budget-page-2',
            },
          ],
          nextCursor: null,
        ),
      );

      await failure;
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        4,
      );
      final cached = await service.loadCachedWindow(
        provider: 'codex',
        providerSessionId: 'thread-latest-turn-byte-budget',
      );
      expect(cached?.latestTurnComplete, isFalse);
      expect(cached?.latestTurnGap?.repair, 'items_page');
      expect(cached?.latestTurnGapCursor, 'latest-turn-byte-budget-page-2');
      expect(cached?.turnsNextCursor, 'older-latest-turn-byte-budget');
      expect(trackingRepository.clearTargetCalls, 0);
    },
  );

  test(
    'retries an older turn page after the subscription is replaced',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      service = ConversationContentSyncService(
        bridge: gateway,
        cache: repository,
        retryBaseDelay: const Duration(milliseconds: 1),
        retryMaxDelay: const Duration(milliseconds: 1),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final firstSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final firstSubscriptionId = firstSubscribe['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-turn-retry-1',
          sequence: 1,
          requestId: firstSubscriptionId,
          catalogState: 'catalog-turn-retry-1',
          statusState: 'status-turn-retry-1',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.timelinePage,
          subscriptionId: firstSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-turn-retry-1',
          sequence: 2,
          provider: 'codex',
          providerSessionId: 'thread-turn-retry',
          revision: 'revision-turn-retry',
          mode: 'snapshot',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('current-retry-entry', 0)],
          hasEarlier: true,
          turnsNextCursor: 'cursor-turn-retry',
          sourceEntryCount: 2,
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final load = service.loadOlderTurns(
        provider: 'codex',
        providerSessionId: 'thread-turn-retry',
      );
      final firstPageRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      expect(firstPageRequest['cursor'], 'cursor-turn-retry');

      gateway.addEvent(
        _catalogRecoveryEvent(
          subscriptionId: firstSubscriptionId,
          batchId: 'batch-turn-retry-1',
          sequence: 4,
          catalogState: 'catalog-turn-retry-gap',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_unsubscribe');

      final secondSubscribe = await gateway.nextOutgoing(
        'conversation_sync_subscribe',
      );
      final secondSubscriptionId = secondSubscribe['requestId']! as String;
      expect(secondSubscriptionId, isNot(firstSubscriptionId));
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-turn-retry-2',
          sequence: 1,
          requestId: secondSubscriptionId,
          catalogState: 'catalog-turn-retry-2',
          statusState: 'status-turn-retry-2',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final retriedPageRequest = await gateway.nextOutgoing(
        'conversation_turns_page',
      );
      expect(
        retriedPageRequest['requestId'],
        isNot(firstPageRequest['requestId']),
      );
      expect(retriedPageRequest['cursor'], 'cursor-turn-retry');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.turnsPageResponse,
          subscriptionId: secondSubscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-turn-retry-2',
          sequence: 2,
          requestId: retriedPageRequest['requestId']! as String,
          provider: 'codex',
          providerSessionId: 'thread-turn-retry',
          data: const [
            {
              'turnId': 'turn-before-retry',
              'messages': [
                {
                  'type': 'user_input',
                  'text': 'Recovered earlier prompt',
                  'userMessageUuid': 'user-before-retry',
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
        providerSessionId: 'thread-turn-retry',
      );
      expect(cached?.entries.map((entry) => entry.entryId), [
        'user:user-before-retry',
        'current-retry-entry',
      ]);
      expect(
        (await gateway.nextOutgoing('conversation_sync_ack'))['sequence'],
        2,
      );
    },
  );

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

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-read',
          sequence: 2,
          statusState: 'status-2',
          pageIndex: 0,
          pageCount: 1,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-read',
              activity: 'idle',
              attention: 'none',
              result: 'completed',
              runtimeAttachment: 'notLoaded',
              source: 'appServer',
              confidence: 'authoritative',
              observedAt: '2026-07-30T01:02:03.000Z',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final readAt = DateTime.utc(2026, 7, 30, 1, 2, 3);
      final committedUpdates = <ConversationSyncCacheUpdate>[];
      final updatesSubscription = service.syncUpdates.listen(
        committedUpdates.add,
      );
      addTearDown(updatesSubscription.cancel);
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
      expect(committedUpdates, hasLength(1));
      expect(committedUpdates.single.replaceExistingReadWatermark, isTrue);
    },
  );

  test(
    'defers a read watermark until an authoritative status clock exists',
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
          batchId: 'batch-read-clock',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-1',
          statusState: 'status-1',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      await service.markConversationRead(
        provider: 'codex',
        providerSessionId: 'thread-read-clock',
        readAt: DateTime.utc(2099, 7, 30),
      );
      expect(
        gateway.sentTypes.where((type) => type == 'conversation_sync_read'),
        isEmpty,
      );
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
      );
      expect(await repository.loadReadWatermarks(target), isEmpty);

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-read-clock',
          sequence: 2,
          statusState: 'status-2',
          pageIndex: 0,
          pageCount: 1,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-read-clock',
              activity: 'idle',
              attention: 'none',
              result: 'completed',
              runtimeAttachment: 'notLoaded',
              source: 'appServer',
              confidence: 'authoritative',
              observedAt: '2026-07-30T00:02:00.000Z',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      await service.markConversationRead(
        provider: 'codex',
        providerSessionId: 'thread-read-clock',
        readAt: DateTime.utc(2099, 7, 30),
      );

      final outgoing = await gateway.nextOutgoing('conversation_sync_read');
      expect(outgoing['readAt'], '2026-07-30T00:02:00.000Z');
      expect(
        (await repository.loadReadWatermarks(target)).single.readAt,
        '2026-07-30T00:02:00.000Z',
      );
    },
  );

  test(
    'manual focused refresh re-sends an unchanged focus and waits for commit',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationSyncFocusRefresh = true;
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
          batchId: 'batch-initial',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-refresh',
          statusState: 'status-refresh',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncComplete,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-initial',
          sequence: 2,
          requestId: subscriptionId,
          nextState: const ConversationSyncV2NextState(
            catalogState: 'catalog-refresh',
            statusState: 'status-refresh',
            threadContentStates: [],
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      var completed = false;
      final refresh = service
          .refreshFocusedConversation(
            provider: 'codex',
            providerSessionId: 'thread-manual-refresh',
            expectedDataSourceIdentity: const BridgeDataSourceIdentity(
              bridgeInstanceId: 'bridge-1',
              codexSourceId: 'codex-home-a',
            ),
          )
          .whenComplete(() => completed = true);
      final duplicateRefresh = service.refreshFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-manual-refresh',
        expectedDataSourceIdentity: const BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      );
      final repeatedFocus = await gateway.nextOutgoing(
        'conversation_sync_focus',
      );
      expect(repeatedFocus['focused'], {
        'provider': 'codex',
        'providerSessionId': 'thread-manual-refresh',
      });
      expect(repeatedFocus['refresh'], isTrue);
      expect(
        gateway.sent.where(
          (message) => message['type'] == 'conversation_sync_focus',
        ),
        hasLength(1),
      );
      final requestId = repeatedFocus['requestId']! as String;
      expect(completed, isFalse);

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.focusApplied,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-manual-refresh',
          sequence: 3,
          requestId: requestId,
          focused: const ConversationSyncV2Target(
            provider: 'codex',
            providerSessionId: 'thread-manual-refresh',
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      // An older in-flight batch may finish after focus_applied. It must not
      // complete the user-visible refresh flight.
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-unrelated',
          sequence: 4,
          requestId: subscriptionId,
          catalogState: 'catalog-refresh',
          statusState: 'status-refresh',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncComplete,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-unrelated',
          sequence: 5,
          nextState: const ConversationSyncV2NextState(
            catalogState: 'catalog-refresh',
            statusState: 'status-refresh',
            threadContentStates: [],
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      expect(completed, isFalse);

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-manual-refresh',
          sequence: 6,
          requestId: subscriptionId,
          catalogState: 'catalog-refresh',
          statusState: 'status-refresh',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncComplete,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-manual-refresh',
          sequence: 7,
          requestId: requestId,
          nextState: const ConversationSyncV2NextState(
            catalogState: 'catalog-refresh',
            statusState: 'status-refresh',
            threadContentStates: [],
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      await refresh;
      await duplicateRefresh;
      expect(completed, isTrue);
    },
  );

  test(
    'focus A to B interrupts the obsolete refresh and starts B immediately',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationSyncFocusRefresh = true;
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
          batchId: 'batch-focus-switch-initial',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-focus-switch',
          statusState: 'status-focus-switch',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncComplete,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-focus-switch-initial',
          sequence: 2,
          requestId: subscriptionId,
          nextState: const ConversationSyncV2NextState(
            catalogState: 'catalog-focus-switch',
            statusState: 'status-focus-switch',
            threadContentStates: [],
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final refreshA = service.refreshFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-focus-a',
        expectedDataSourceIdentity: const BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      );
      final refreshAResult = expectLater(refreshA, throwsA(isA<Object>()));
      final focusA = await gateway.nextOutgoing('conversation_sync_focus');
      expect(focusA['refresh'], isTrue);
      expect(
        (focusA['focused']! as Map<String, dynamic>)['providerSessionId'],
        'thread-focus-a',
      );

      service.setFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-focus-b',
      );
      final ordinaryFocusB = await gateway.nextOutgoing(
        'conversation_sync_focus',
      );
      expect(ordinaryFocusB, isNot(contains('refresh')));

      final refreshB = service.refreshFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-focus-b',
        expectedDataSourceIdentity: const BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      );
      final focusB = await gateway
          .nextOutgoing('conversation_sync_focus')
          .timeout(const Duration(seconds: 1));
      expect(focusB['refresh'], isTrue);
      expect(
        (focusB['focused']! as Map<String, dynamic>)['providerSessionId'],
        'thread-focus-b',
      );
      await refreshAResult;

      final requestId = focusB['requestId']! as String;
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.focusApplied,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-focus-switch-b',
          sequence: 3,
          requestId: requestId,
          focused: const ConversationSyncV2Target(
            provider: 'codex',
            providerSessionId: 'thread-focus-b',
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncBegin,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-focus-switch-b',
          sequence: 4,
          requestId: subscriptionId,
          catalogState: 'catalog-focus-switch',
          statusState: 'status-focus-switch',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncComplete,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-focus-switch-b',
          sequence: 5,
          requestId: requestId,
          nextState: const ConversationSyncV2NextState(
            catalogState: 'catalog-focus-switch',
            statusState: 'status-focus-switch',
            threadContentStates: [],
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      await refreshB;
    },
  );

  test('focus A to B to C never revives the obsolete B refresh', () async {
    await service.dispose();
    gateway.supportsConversationSyncV2 = true;
    gateway.supportsConversationSyncFocusRefresh = true;
    service = ConversationContentSyncService(bridge: gateway, cache: repository)
      ..start(initialLifecycleState: AppLifecycleState.resumed);
    final subscriptionId = await _bootstrapFocusedRefreshTest(
      gateway,
      'focus-abc',
    );
    const identity = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-home-a',
    );

    final refreshA = service.refreshFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-a',
      expectedDataSourceIdentity: identity,
    );
    final refreshAResult = expectLater(refreshA, throwsA(isA<Object>()));
    expect(
      _focusedThread(await gateway.nextOutgoing('conversation_sync_focus')),
      'thread-focus-a',
    );

    service.setFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-b',
    );
    expect(
      _focusedThread(await gateway.nextOutgoing('conversation_sync_focus')),
      'thread-focus-b',
    );
    final refreshB = service.refreshFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-b',
      expectedDataSourceIdentity: identity,
    );
    final refreshBResult = expectLater(refreshB, throwsA(isA<Object>()));

    service.setFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-c',
    );
    final refreshC = service.refreshFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-c',
      expectedDataSourceIdentity: identity,
    );
    final queued = <Map<String, dynamic>>[
      await gateway.nextOutgoing('conversation_sync_focus'),
      await gateway.nextOutgoing('conversation_sync_focus'),
      await gateway.nextOutgoing('conversation_sync_focus'),
    ];
    final focusC = queued.lastWhere(
      (message) =>
          _focusedThread(message) == 'thread-focus-c' &&
          message['refresh'] == true,
    );

    await refreshAResult;
    await refreshBResult;
    await _completeFocusedRefreshTest(
      gateway: gateway,
      subscriptionId: subscriptionId,
      focus: focusC,
      suffix: 'focus-abc',
    );
    await refreshC;
    await pumpEventQueue();

    final focusMessages = gateway.sent
        .where((message) => message['type'] == 'conversation_sync_focus')
        .toList(growable: false);
    final firstC = focusMessages.indexWhere(
      (message) => _focusedThread(message) == 'thread-focus-c',
    );
    expect(firstC, isNonNegative);
    expect(
      focusMessages
          .skip(firstC)
          .map(_focusedThread)
          .whereType<String>()
          .toSet(),
      {'thread-focus-c'},
    );
  });

  test('focus A to B to A starts a new A refresh generation', () async {
    await service.dispose();
    gateway.supportsConversationSyncV2 = true;
    gateway.supportsConversationSyncFocusRefresh = true;
    service = ConversationContentSyncService(bridge: gateway, cache: repository)
      ..start(initialLifecycleState: AppLifecycleState.resumed);
    final subscriptionId = await _bootstrapFocusedRefreshTest(
      gateway,
      'focus-aba',
    );
    const identity = BridgeDataSourceIdentity(
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-home-a',
    );

    final firstRefreshA = service.refreshFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-a',
      expectedDataSourceIdentity: identity,
    );
    final firstAResult = expectLater(firstRefreshA, throwsA(isA<Object>()));
    final firstFocusA = await gateway.nextOutgoing('conversation_sync_focus');

    service.setFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-b',
    );
    await gateway.nextOutgoing('conversation_sync_focus');
    final refreshB = service.refreshFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-b',
      expectedDataSourceIdentity: identity,
    );
    final refreshBResult = expectLater(refreshB, throwsA(isA<Object>()));

    service.setFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-a',
    );
    final secondRefreshA = service.refreshFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-focus-a',
      expectedDataSourceIdentity: identity,
    );
    final queued = <Map<String, dynamic>>[
      await gateway.nextOutgoing('conversation_sync_focus'),
      await gateway.nextOutgoing('conversation_sync_focus'),
      await gateway.nextOutgoing('conversation_sync_focus'),
    ];
    final secondFocusA = queued.lastWhere(
      (message) =>
          _focusedThread(message) == 'thread-focus-a' &&
          message['refresh'] == true,
    );
    expect(secondFocusA['requestId'], isNot(firstFocusA['requestId']));

    await firstAResult;
    await refreshBResult;
    await _completeFocusedRefreshTest(
      gateway: gateway,
      subscriptionId: subscriptionId,
      focus: secondFocusA,
      suffix: 'focus-aba',
    );
    await secondRefreshA;
  });

  test('manual focused refresh rejects a different data source', () async {
    final before = gateway.sent
        .where((message) => message['type'] == 'conversation_sync_focus')
        .length;
    await expectLater(
      service.refreshFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-wrong-source',
        expectedDataSourceIdentity: const BridgeDataSourceIdentity(
          bridgeInstanceId: 'other-bridge',
          codexSourceId: 'codex-home-a',
        ),
      ),
      throwsA(isA<Object>()),
    );
    expect(
      gateway.sent.where(
        (message) => message['type'] == 'conversation_sync_focus',
      ),
      hasLength(before),
    );
  });

  test(
    'manual focused refresh falls back to exact v2 focus acknowledgement',
    () async {
      await service.dispose();
      gateway.supportsConversationSyncV2 = true;
      gateway.supportsConversationSyncFocusRefresh = false;
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
          batchId: 'batch-legacy-focus',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-legacy-focus',
          statusState: 'status-legacy-focus',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.syncComplete,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-legacy-focus',
          sequence: 2,
          nextState: const ConversationSyncV2NextState(
            catalogState: 'catalog-legacy-focus',
            statusState: 'status-legacy-focus',
            threadContentStates: [],
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      final refresh = service.refreshFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-legacy-focus',
        expectedDataSourceIdentity: const BridgeDataSourceIdentity(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      );
      final focus = await gateway.nextOutgoing('conversation_sync_focus');
      expect(focus, isNot(contains('refresh')));
      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.focusApplied,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-legacy-focus',
          sequence: 3,
          requestId: focus['requestId']! as String,
          focused: const ConversationSyncV2Target(
            provider: 'codex',
            providerSessionId: 'thread-legacy-focus',
          ),
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');
      await refresh;
    },
  );

  test('manual focused refresh keeps the v1 content-focus fallback', () async {
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
    await Future<void>.delayed(Duration.zero);

    await service.refreshFocusedConversation(
      provider: 'codex',
      providerSessionId: 'thread-v1-focus',
      expectedDataSourceIdentity: const BridgeDataSourceIdentity(
        bridgeInstanceId: 'bridge-1',
        codexSourceId: 'codex-home-a',
      ),
    );
    final focus = await gateway.nextOutgoing('conversation_content_focus');
    expect(focus['subscriptionId'], subscriptionId);
    expect(focus['focused'], {
      'provider': 'codex',
      'providerSessionId': 'thread-v1-focus',
    });
  });

  test(
    'durable focus marks read on entry and again on exit after a newer status',
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
          batchId: 'batch-focus-read',
          sequence: 1,
          requestId: subscriptionId,
          catalogState: 'catalog-1',
          statusState: 'status-1',
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-focus-read',
          sequence: 2,
          statusState: 'status-2',
          pageIndex: 0,
          pageCount: 1,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-focus-read',
              activity: 'idle',
              attention: 'none',
              result: 'completed',
              runtimeAttachment: 'notLoaded',
              source: 'appServer',
              confidence: 'authoritative',
              observedAt: '2026-07-30T01:02:03.000Z',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      service.setFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-focus-read',
      );
      final focusEntry = await gateway.nextOutgoing('conversation_sync_focus');
      expect(focusEntry['focused'], {
        'provider': 'codex',
        'providerSessionId': 'thread-focus-read',
      });
      final entryRead = await gateway.nextOutgoing('conversation_sync_read');
      expect(entryRead['providerSessionId'], 'thread-focus-read');

      gateway.addEvent(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.statusChanges,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
          batchId: 'batch-focus-read',
          sequence: 3,
          statusState: 'status-3',
          pageIndex: 0,
          pageCount: 1,
          statusChanges: const [
            ConversationSyncV2Status(
              provider: 'codex',
              providerSessionId: 'thread-focus-read',
              activity: 'idle',
              attention: 'none',
              result: 'completed',
              runtimeAttachment: 'notLoaded',
              source: 'appServer',
              confidence: 'authoritative',
              observedAt: '2099-07-30T01:02:03.000Z',
            ),
          ],
        ),
      );
      await gateway.nextOutgoing('conversation_sync_ack');

      service.clearFocusedConversation(
        provider: 'codex',
        providerSessionId: 'thread-focus-read',
      );
      final focusExit = await gateway.nextOutgoing('conversation_sync_focus');
      expect(focusExit['focused'], isNull);
      final exitRead = await gateway.nextOutgoing('conversation_sync_read');
      expect(exitRead['providerSessionId'], 'thread-focus-read');
      expect(exitRead['readAt'], '2099-07-30T01:02:03.000Z');

      final stored = await repository.loadReadWatermarks(
        SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-1',
          codexSourceId: 'codex-home-a',
        ),
      );
      expect(stored.single.readAt, '2099-07-30T01:02:03.000Z');
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

  test(
    'publishes a committed snapshot even when its ACK write fails',
    () async {
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
          providerSessionId: 'thread-ack-failure',
          revision: 'revision-ack-failure',
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
          providerSessionId: 'thread-ack-failure',
          revision: 'revision-ack-failure',
          pageIndex: 0,
          pageCount: 1,
          entries: [_wireEntry('entry-ack-failure', 0)],
        ),
      );
      final committedUpdate = service.updates.firstWhere(
        (update) => update.providerSessionId == 'thread-ack-failure',
      );
      gateway.throwOnConversationContentAck = true;
      gateway.addEvent(
        ConversationContentEventMessage(
          event: ConversationContentEventKind.snapshotComplete,
          subscriptionId: subscriptionId,
          bridgeInstanceId: 'bridge-1',
          provider: 'codex',
          providerSessionId: 'thread-ack-failure',
          revision: 'revision-ack-failure',
          entryCount: 1,
          hasEarlier: false,
          sourceEntryCount: 1,
        ),
      );

      expect((await committedUpdate).revision, 'revision-ack-failure');
      expect(
        service.cacheCommitEpochFor(
          targetFingerprint: SessionCatalogCacheTarget.fromBridge(
            bridgeInstanceId: 'bridge-1',
            codexSourceId: 'codex-home-a',
            logicalConnectionIdentity: 'machine:1',
            websocketUrl: 'wss://bridge.example/socket',
          ).fingerprint,
          provider: 'codex',
          providerSessionId: 'thread-ack-failure',
        ),
        greaterThan(0),
      );
    },
  );

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

ConversationContentWireEntry _assistantWireEntry(
  String id,
  int index, {
  required String receivedAt,
}) => ConversationContentWireEntry(
  entryId: id,
  index: index,
  contentHash: 'hash-$id-assistant',
  rawMessage: {
    'type': 'assistant',
    'receivedAt': receivedAt,
    'message': {
      'id': id,
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'Visible update'},
      ],
    },
  },
);

Future<String> _bootstrapFocusedRefreshTest(
  FakeConversationContentGateway gateway,
  String suffix,
) async {
  final subscribe = await gateway.nextOutgoing('conversation_sync_subscribe');
  final subscriptionId = subscribe['requestId']! as String;
  gateway.addEvent(
    ConversationSyncV2EventMessage(
      event: ConversationSyncV2EventKind.syncBegin,
      subscriptionId: subscriptionId,
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-home-a',
      batchId: 'batch-$suffix-initial',
      sequence: 1,
      requestId: subscriptionId,
      catalogState: 'catalog-$suffix',
      statusState: 'status-$suffix',
    ),
  );
  await gateway.nextOutgoing('conversation_sync_ack');
  gateway.addEvent(
    ConversationSyncV2EventMessage(
      event: ConversationSyncV2EventKind.syncComplete,
      subscriptionId: subscriptionId,
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-home-a',
      batchId: 'batch-$suffix-initial',
      sequence: 2,
      requestId: subscriptionId,
      nextState: ConversationSyncV2NextState(
        catalogState: 'catalog-$suffix',
        statusState: 'status-$suffix',
        threadContentStates: const [],
      ),
    ),
  );
  await gateway.nextOutgoing('conversation_sync_ack');
  return subscriptionId;
}

Future<void> _completeFocusedRefreshTest({
  required FakeConversationContentGateway gateway,
  required String subscriptionId,
  required Map<String, dynamic> focus,
  required String suffix,
}) async {
  final requestId = focus['requestId']! as String;
  final focused = focus['focused']! as Map<String, dynamic>;
  gateway.addEvent(
    ConversationSyncV2EventMessage(
      event: ConversationSyncV2EventKind.focusApplied,
      subscriptionId: subscriptionId,
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-home-a',
      batchId: 'batch-$suffix',
      sequence: 3,
      requestId: requestId,
      focused: ConversationSyncV2Target(
        provider: focused['provider']! as String,
        providerSessionId: focused['providerSessionId']! as String,
      ),
    ),
  );
  await gateway.nextOutgoing('conversation_sync_ack');
  gateway.addEvent(
    ConversationSyncV2EventMessage(
      event: ConversationSyncV2EventKind.syncBegin,
      subscriptionId: subscriptionId,
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-home-a',
      batchId: 'batch-$suffix',
      sequence: 4,
      requestId: subscriptionId,
      catalogState: 'catalog-$suffix',
      statusState: 'status-$suffix',
    ),
  );
  await gateway.nextOutgoing('conversation_sync_ack');
  gateway.addEvent(
    ConversationSyncV2EventMessage(
      event: ConversationSyncV2EventKind.syncComplete,
      subscriptionId: subscriptionId,
      bridgeInstanceId: 'bridge-1',
      codexSourceId: 'codex-home-a',
      batchId: 'batch-$suffix',
      sequence: 5,
      requestId: requestId,
      nextState: ConversationSyncV2NextState(
        catalogState: 'catalog-$suffix',
        statusState: 'status-$suffix',
        threadContentStates: const [],
      ),
    ),
  );
  await gateway.nextOutgoing('conversation_sync_ack');
}

String? _focusedThread(Map<String, dynamic> focus) =>
    (focus['focused'] as Map<String, dynamic>?)?['providerSessionId']
        as String?;

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
  Future<void> applyConversationCatalogBatch({
    required SessionCatalogCacheTarget target,
    required String codexSourceId,
    required String catalogState,
    required List<ConversationSyncV2CatalogEntry> created,
    required List<ConversationSyncV2CatalogEntry> updated,
    required List<ConversationSyncV2Target> destroyed,
    bool Function()? isCurrent,
  }) {
    if (catalogFailuresRemaining > 0) {
      catalogFailuresRemaining -= 1;
      return Future<void>.error(StateError('injected catalog failure'));
    }
    return super.applyConversationCatalogBatch(
      target: target,
      codexSourceId: codexSourceId,
      catalogState: catalogState,
      created: created,
      updated: updated,
      destroyed: destroyed,
      isCurrent: isCurrent,
    );
  }

  @override
  Future<void> clearTarget(SessionCatalogCacheTarget target) {
    clearTargetCalls += 1;
    return super.clearTarget(target);
  }
}

class _FailingLatestTurnRepairRepository extends SessionCatalogCacheRepository {
  _FailingLatestTurnRepairRepository(super.database);

  int clearTargetCalls = 0;

  @override
  Future<ConversationHotWindowSnapshot?> mergeConversationLatestTurnItemsPage({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String expectedRevision,
    required String expectedTurnId,
    required List<Map<String, dynamic>> rawMessages,
    required String? nextCursor,
    bool pageComplete = true,
    ConversationSyncV2LatestTurnGap? latestTurnGap,
  }) {
    return Future<ConversationHotWindowSnapshot?>.error(
      StateError('injected latest-turn merge failure'),
    );
  }

  @override
  Future<ConversationHotWindowSnapshot?>
  replaceConversationLatestTurnsRepairPage({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String expectedRevision,
    required List<Map<String, dynamic>> rawMessages,
    required String? turnsNextCursor,
  }) {
    return Future<ConversationHotWindowSnapshot?>.error(
      StateError('injected latest-turn replace failure'),
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
  bool throwOnConversationContentAck = false;

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
  bool supportsConversationWindowCoverage = true;

  @override
  bool supportsConversationSyncFocusRefresh = false;

  @override
  bool supportsConversationItemsById = true;

  @override
  bool supportsConversationUserIndex = false;

  @override
  BridgeClientDeliveryMode desiredClientDeliveryMode =
      BridgeClientDeliveryMode.interactive;

  @override
  void send(ClientMessage message) {
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    if (throwOnConversationContentAck &&
        json['type'] == 'conversation_content_ack') {
      throw StateError('injected conversation content ACK failure');
    }
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
