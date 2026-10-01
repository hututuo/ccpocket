import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'chat_screen/helpers/chat_test_helpers.dart';
import 'chat_screen/helpers/page_platform_services.dart';

// This fixture starts at the Service's incoming-event seam. The four Bridge
// blackboxes cover the transport above it. Every returned window comes from
// real SQLite; barriers delay the return or throw a read-boundary error only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets('a late read error from another source stays off the page', (
    tester,
  ) async {
    await _withPreview(tester, (fixture) async {
      await fixture.commit('thread', 'initial', 'Last good source A');
      await fixture.mount('thread');
      await fixture.visible('Last good source A');

      final read = fixture.sync.holdNextRead();
      await fixture.commit('thread', 'next', 'Unread source A');
      await fixture.waitFor(() => read.arrived.isCompleted);
      fixture.bridge.authenticatedCodexSourceId = 'source-b';
      fixture.bridge.emitSessionList(const []);
      await tester.pump();
      expect(
        fixture.sync.hasAuthoritativeDataSourceConflict(
          fixture.identity,
          provider: 'codex',
        ),
        isTrue,
      );

      read.release(error: StateError('late source A read failure'));
      await fixture.waitFor(() => read.finished.isCompleted);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Last good source A'), findsOneWidget);
      expect(find.text('Unread source A'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('SQLite commits coalesce without flashing an obsolete window', (
    tester,
  ) async {
    await _withPreview(tester, (fixture) async {
      await fixture.commit('thread', 'initial', 'Obsolete window');
      final read = fixture.sync.holdNextRead();
      await fixture.mount('thread');
      await fixture.waitFor(() => read.arrived.isCompleted);
      expect(read.snapshot?.revision, 'initial');

      for (var index = 1; index <= 4; index++) {
        await fixture.commit(
          'thread',
          'next-$index',
          'Committed window $index',
        );
      }
      expect(fixture.sync.readCalls, 1);
      read.release();
      await fixture.visible('Committed window 4', forbidden: 'Obsolete window');
      await tester.pump(const Duration(milliseconds: 50));
      expect(fixture.sync.readCalls, 2);
      final cached = await fixture.cached('thread');
      expect(cached?.revision, 'next-4');
      expect(cached?.entries.single.entryId, 'user:thread:next-4');
      expect(
        fixture.cubit().state.entries.whereType<UserChatEntry>().map(
          (entry) => entry.messageUuid,
        ),
        ['user:thread:next-4'],
      );
    });
  });

  for (final failOldRead in [false, true]) {
    testWidgets(
      'old thread ${failOldRead ? 'error' : 'completion'} cannot retire a new read',
      (tester) async {
        await _withPreview(tester, (fixture) async {
          await fixture.commit('old', 'initial-old', 'Old thread');
          await fixture.commit(
            'new',
            'initial-new',
            'New thread before commit',
          );
          final old = fixture.sync.holdNextRead();
          await fixture.mount('old');
          await fixture.waitFor(() => old.arrived.isCompleted);
          final next = fixture.sync.holdNextRead();
          await fixture.mount('new');
          await fixture.waitFor(() => next.arrived.isCompleted);

          old.release(error: failOldRead ? StateError('retired read') : null);
          await fixture.waitFor(() => old.finished.isCompleted);
          await fixture.commit('new', 'new-committed', 'New thread committed');
          expect(fixture.sync.readCalls, 2);
          expect(find.byType(SnackBar), findsNothing);
          next.release();
          await fixture.visible(
            'New thread committed',
            forbidden: 'Old thread',
          );
          expect(find.text('New thread before commit'), findsNothing);
          expect(fixture.sync.readCalls, 3);
          expect(tester.takeException(), isNull);
        });
      },
    );
  }

  testWidgets('a failed reread retains last good content and retries SQLite', (
    tester,
  ) async {
    await _withPreview(tester, (fixture) async {
      await fixture.commit('thread', 'initial', 'Last good window');
      await fixture.mount('thread');
      await fixture.visible('Last good window');
      final read = fixture.sync.holdNextRead();
      await fixture.commit('thread', 'next', 'Recovered window');
      await fixture.waitFor(() => read.arrived.isCompleted);
      read.release(error: StateError('current read failure'));
      await fixture.waitFor(() => find.byType(SnackBar).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Last good window'), findsOneWidget);
      expect(find.text('Recovered window'), findsNothing);
      await tester.tap(find.text('Retry'));
      await fixture.visible('Recovered window');
      expect(find.text('Last good window'), findsNothing);
      expect(fixture.sync.readCalls, 3);

      // A completed retry must not leave the loading owner stuck.
      await fixture.commit('thread', 'after-retry', 'After retry');
      await fixture.visible('After retry');
      expect(fixture.sync.readCalls, 4);
    });
  });

  testWidgets(
    'a complete v2 empty SQLite window clears old canonical content',
    (tester) async {
      await _withPreview(tester, (fixture) async {
        await fixture.commit('thread', 'initial', 'Content before empty');
        await fixture.mount('thread');
        await fixture.visible('Content before empty');
        await fixture.commit('thread', 'empty', null);
        await fixture.waitFor(
          () => find.text('Content before empty').evaluate().isEmpty,
        );
        expect((await fixture.cached('thread'))?.entries, isEmpty);
        expect(
          fixture.cubit().state.entries.whereType<UserChatEntry>(),
          isEmpty,
        );
      });
    },
  );
}

Future<void> _withPreview(
  WidgetTester tester,
  Future<void> Function(_PreviewFixture) body,
) async {
  await tester.binding.setSurfaceSize(const Size(430, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await installPagePlatformServices();
    final fixture = await _PreviewFixture.create(tester);
    try {
      await body(fixture);
    } finally {
      await fixture.dispose();
    }
  });
}

class _PreviewFixture {
  _PreviewFixture(this.tester, this.directory, this.bridge, this.repository)
    : identity = bridge.dataSourceIdentity {
    sync = _HeldReadSync(
      bridge: BridgeServiceConversationContentSyncGateway(bridge),
      cache: repository,
    )..start(initialLifecycleState: AppLifecycleState.resumed);
  }

  final WidgetTester tester;
  final Directory directory;
  final _PreviewBridge bridge;
  final SessionCatalogCacheRepository repository;
  final BridgeDataSourceIdentity identity;
  late final _HeldReadSync sync;
  late String subscription;
  var sequence = 0;

  static Future<_PreviewFixture> create(WidgetTester tester) async {
    final directory = await Directory.systemTemp.createTemp('ccpocket_read_');
    final bridge = _PreviewBridge()
      ..authenticatedBridgeInstanceId = 'bridge-read'
      ..authenticatedCodexSourceId = 'source-a';
    final repository = SessionCatalogCacheRepository(
      SessionCatalogCacheDatabase(
        databasePath: path.join(directory.path, 'cache.db'),
        openDatabase: (file, options) =>
            databaseFactoryFfi.openDatabase(file, options: options),
      ),
    );
    final fixture = _PreviewFixture(tester, directory, bridge, repository);
    await fixture.waitFor(
      () => bridge.sentMessages.any(
        (message) =>
            _messageJson(message)['type'] == 'conversation_sync_subscribe',
      ),
    );
    fixture.subscription =
        _messageJson(
              bridge.sentMessages.firstWhere(
                (message) =>
                    _messageJson(message)['type'] ==
                    'conversation_sync_subscribe',
              ),
            )['requestId']
            as String;
    bridge.emitLocalFeatureMessage(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.syncBegin,
        subscriptionId: fixture.subscription,
        requestId: fixture.subscription,
        bridgeInstanceId: bridge.bridgeInstanceId!,
        codexSourceId: bridge.codexSourceId!,
        batchId: 'begin',
        sequence: ++fixture.sequence,
        catalogState: 'catalog',
        statusState: 'status',
      ),
    );
    await fixture.ack();
    return fixture;
  }

  Future<void> commit(String thread, String revision, String? text) async {
    bridge.emitLocalFeatureMessage(
      ConversationSyncV2EventMessage(
        event: ConversationSyncV2EventKind.timelinePage,
        subscriptionId: subscription,
        bridgeInstanceId: identity.bridgeInstanceId!,
        codexSourceId: identity.codexSourceId!,
        batchId: 'page-${sequence + 1}',
        sequence: ++sequence,
        provider: 'codex',
        providerSessionId: thread,
        revision: revision,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: text == null
            ? const []
            : [
                ConversationContentWireEntry(
                  entryId: 'user:$thread:$revision',
                  index: 0,
                  contentHash: 'hash:$revision',
                  rawMessage: {
                    'type': 'user_input',
                    'text': text,
                    'userMessageUuid': 'user:$thread:$revision',
                  },
                ),
              ],
        deletes: const [],
        hasEarlier: false,
        windowComplete: true,
        latestTurnComplete: true,
        sourceEntryCount: text == null ? 0 : 1,
      ),
    );
    await ack();
    expect((await cached(thread))?.revision, revision);
    await tester.pump();
  }

  Future<void> ack() => waitFor(
    () => bridge.sentMessages.any((message) {
      final json = _messageJson(message);
      return json['type'] == 'conversation_sync_ack' &&
          json['sequence'] == sequence;
    }),
  );

  Future<ConversationHotWindowSnapshot?> cached(String thread) =>
      repository.loadConversationWindow(
        target: SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: identity.bridgeInstanceId,
          codexSourceId: identity.codexSourceId,
        ),
        provider: 'codex',
        providerSessionId: thread,
      );

  Future<void> mount(String thread) async {
    await tester.pumpWidget(
      await buildTestCodexSessionScreen(
        bridge: bridge,
        sessionId: 'pending-$thread',
        isPending: true,
        durableProviderSessionId: thread,
        dataSourceIdentity: identity,
        conversationContentSync: sync,
      ),
    );
  }

  ChatSessionCubit cubit() => tester
      .element(find.byType(DurableSessionPreviewUpdater))
      .read<ChatSessionCubit>();

  Future<void> visible(String text, {String? forbidden}) => waitFor(() {
    if (forbidden != null) expect(find.text(forbidden), findsNothing);
    return find.text(text).evaluate().isNotEmpty;
  });

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Preview fixture condition did not finish');
      }
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await tester.pump();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final read in sync.heldReads) {
      read.release();
    }
    await tester.pump();
    await sync.dispose();
    await repository.close();
    bridge.dispose();
    await directory.delete(recursive: true);
  }
}

Map<String, dynamic> _messageJson(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

class _PreviewBridge extends MockBridgeService {
  @override
  BridgeConnectionState get currentBridgeConnectionState => connected
      ? BridgeConnectionState.connected
      : BridgeConnectionState.disconnected;

  @override
  bool get supportsConversationSyncV2 => true;
}

class _HeldRead {
  final arrived = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();
  ConversationHotWindowSnapshot? snapshot;
  Object? error;

  void release({Object? error}) {
    if (_released.isCompleted) return;
    this.error = error;
    _released.complete();
  }
}

class _HeldReadSync extends ConversationContentSyncService {
  _HeldReadSync({required super.bridge, required super.cache});
  final heldReads = <_HeldRead>[];
  final _pendingReads = <_HeldRead>[];
  int readCalls = 0;

  _HeldRead holdNextRead() {
    final read = _HeldRead();
    heldReads.add(read);
    _pendingReads.add(read);
    return read;
  }

  @override
  Future<ConversationHotWindowSnapshot?> loadCachedWindow({
    required String provider,
    required String providerSessionId,
    BridgeDataSourceIdentity? expectedDataSourceIdentity,
  }) async {
    readCalls++;
    final read = _pendingReads.isEmpty ? null : _pendingReads.removeAt(0);
    try {
      final snapshot = await super.loadCachedWindow(
        provider: provider,
        providerSessionId: providerSessionId,
        expectedDataSourceIdentity: expectedDataSourceIdentity,
      );
      if (read != null) {
        read.snapshot = snapshot;
        read.arrived.complete();
        await read._released.future;
        if (read.error != null) throw read.error!;
      }
      return snapshot;
    } finally {
      read?.finished.complete();
    }
  }
}
