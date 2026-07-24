import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ccpocket/features/conversation_mirror/conversation_mirror_service.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_target.dart';
import 'package:ccpocket/features/conversation_mirror/storage/conversation_mirror_storage.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _GateableMirrorStore extends ConversationMirrorStore {
  _GateableMirrorStore(super.database);

  Completer<void>? readStarted;
  Completer<void>? readGate;

  @override
  Future<List<ConversationMirrorEntry>> readEntries(
    ConversationMirrorKey key, {
    int offset = 0,
    int? limit,
  }) async {
    final started = readStarted;
    if (started != null && !started.isCompleted) started.complete();
    await readGate?.future;
    return super.readEntries(key, offset: offset, limit: limit);
  }
}

class _MirrorTestBridge extends BridgeService {
  final _localFeatures =
      StreamController<LocalFeatureServerMessage>.broadcast();
  final _connections = StreamController<BridgeConnectionState>.broadcast();
  final _promptHistory =
      StreamController<PromptHistoryStatusMessage>.broadcast();

  final sent = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic> message)? onSend;
  bool connected = true;
  String? bridgeId = 'bridge-test';
  int contentEpoch = 0;
  int Function()? onReadContentEpoch;
  String? runtimeProviderSessionId = 'provider-session-1';
  List<ServerMessage> canonicalMessages = const [];
  final externallyPublishedHistories = <List<ServerMessage>>[];
  final externallyPublishedTimestampAnchors = <DateTime?>[];

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      _localFeatures.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;

  @override
  Stream<PromptHistoryStatusMessage> get promptHistoryStatus =>
      _promptHistory.stream;

  @override
  bool get isConnected => connected;

  @override
  String? get promptHistoryBridgeId => bridgeId;

  @override
  String? providerSessionIdForRuntime(
    String runtimeSessionId, {
    String? provider,
  }) => runtimeProviderSessionId;

  @override
  int cachedSessionContentEpoch(String sessionId) =>
      onReadContentEpoch?.call() ?? contentEpoch;

  @override
  List<ServerMessage> cachedSessionMessages(String sessionId) =>
      List.unmodifiable(canonicalMessages);

  @override
  List<String> runtimeSessionIdsForProviderSession(
    String provider,
    String providerSessionId,
  ) => runtimeProviderSessionId == providerSessionId
      ? const ['runtime-1']
      : const [];

  @override
  void send(ClientMessage message) {
    final decoded = jsonDecode(message.toJson()) as Map<String, dynamic>;
    sent.add(decoded);
    onSend?.call(decoded);
  }

  void emit(LocalFeatureServerMessage message) => _localFeatures.add(message);

  void emitConnection(BridgeConnectionState state) => _connections.add(state);

  @override
  void publishExternalSessionHistory(
    String runtimeSessionId,
    List<ServerMessage> messages, {
    DateTime? timestampAnchor,
  }) {
    externallyPublishedHistories.add(List.unmodifiable(messages));
    externallyPublishedTimestampAnchors.add(timestampAnchor);
    super.publishExternalSessionHistory(
      runtimeSessionId,
      messages,
      timestampAnchor: timestampAnchor,
    );
  }

  @override
  void dispose() {
    _localFeatures.close();
    _connections.close();
    _promptHistory.close();
    super.dispose();
  }
}

void main() {
  late Directory temporaryDirectory;
  late ConversationMirrorDatabase database;
  late _GateableMirrorStore store;
  late _MirrorTestBridge bridge;
  late ConversationMirrorService service;

  Future<Database> openFfi(String databasePath, OpenDatabaseOptions options) =>
      databaseFactoryFfi.openDatabase(databasePath, options: options);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'ccpocket_conversation_mirror_service_test_',
    );
    database = ConversationMirrorDatabase(
      databasePath: path.join(
        temporaryDirectory.path,
        ConversationMirrorDatabase.fileName,
      ),
      openDatabase: openFfi,
    );
    store = _GateableMirrorStore(database);
    bridge = _MirrorTestBridge();
    service = ConversationMirrorService(
      bridge: bridge,
      store: store,
      database: database,
    );
    await service.initialize();
  });

  tearDown(() async {
    await service.close();
    bridge.dispose();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'new iOS client falls back cleanly when an old Bridge rejects mirror',
    () async {
      bridge.onSend = (request) {
        scheduleMicrotask(() {
          bridge.emit(
            LocalFeatureRequestErrorMessage(
              featureId: 'conversation_mirror',
              ownerSessionId: request['providerSessionId'] as String,
              requestType: request['type'] as String,
              requestId: request['requestId'] as String,
              message: request['type'] as String,
              errorCode: 'unsupported_message',
            ),
          );
        });
      };

      final result = await service.downloadAndWatch(_recentSession);

      expect(result.success, isFalse);
      expect(result.errorCode, 'unsupported_message');
      expect(service.featureUnsupported, isTrue);
      expect(await service.metadataFor(_recentSession), isNull);
      expect(bridge.sent.single['type'], 'conversation_mirror_watch');
    },
  );

  test(
    'a correlated generic old-Bridge error does not send an unknown unwatch',
    () async {
      bridge.onSend = (request) {
        scheduleMicrotask(() {
          bridge.emit(
            LocalFeatureRequestErrorMessage(
              featureId: 'conversation_mirror',
              ownerSessionId: request['providerSessionId'] as String,
              requestType: request['type'] as String,
              requestId: request['requestId'] as String,
              message: 'Unknown message type: ${request['type']}',
              errorCode: 'unknown_error',
            ),
          );
        });
      };

      final result = await service.downloadAndWatch(_recentSession);

      expect(result.errorCode, 'capability_not_negotiated');
      expect(service.featureUnsupported, isTrue);
      expect(bridge.sent.single['type'], 'conversation_mirror_watch');
    },
  );

  test('reassembles a large entry snapshot without the 512 KiB failure', () async {
    final download = service.downloadAndWatch(_recentSession);
    await _waitUntil(() async => bridge.sent.isNotEmpty);
    final requestId = bridge.sent.single['requestId'] as String;
    final revision = _hashText('large-fragmented-entry');
    final message = <String, dynamic>{
      'type': 'tool_result',
      'toolUseId': 'large-tool-result',
      'content': 'x' * 700000,
    };
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    final contentHash = sha256.convert(payload).toString();
    const chunkSize = 256 * 1024;
    final chunks = <Uint8List>[];
    for (var offset = 0; offset < payload.length; offset += chunkSize) {
      chunks.add(
        Uint8List.sublistView(
          payload,
          offset,
          math.min(offset + chunkSize, payload.length),
        ),
      );
    }
    bridge
      ..emit(_event(requestId: requestId, event: 'accepted'))
      ..emit(
        _event(
          requestId: requestId,
          event: 'watching',
          revision: revision,
          threadStatus: 'idle',
        ),
      )
      ..emit(
        _event(
          requestId: requestId,
          event: 'snapshot_begin',
          revision: revision,
          entryCount: 1,
          pageCount: 1,
          totalBytes: payload.length,
          threadStatus: 'idle',
        ),
      );
    // Delivery order is not trusted by the reassembler. A repeated identical
    // chunk is idempotent; conflicting duplicates are rejected.
    for (final chunkIndex in [2, 0, 0, 1]) {
      bridge.emit(
        ConversationMirrorEntryChunkMessage(
          requestId: requestId,
          bridgeInstanceId: 'bridge-test',
          provider: 'codex',
          providerSessionId: 'provider-session-1',
          revision: revision,
          pageIndex: 0,
          pageCount: 1,
          entryId: 'large-entry',
          index: 0,
          contentHash: contentHash,
          chunkIndex: chunkIndex,
          chunkCount: chunks.length,
          totalBytes: payload.length,
          payloadBase64: base64Encode(chunks[chunkIndex]),
        ),
      );
    }
    bridge.emit(
      _event(
        requestId: requestId,
        event: 'snapshot_complete',
        revision: revision,
        entryCount: 1,
        threadStatus: 'idle',
      ),
    );

    final result = await download;
    final metadata = await service.metadataFor(_recentSession);
    final stored = await store.readEntries(metadata!.key);

    expect(result.success, isTrue);
    expect(stored.single.entryId, 'large-entry');
    expect(stored.single.message['content'], 'x' * 700000);
  });

  test(
    'a silent pre-feature Bridge falls back on the short first-frame deadline',
    () async {
      final isolatedDirectory = await Directory.systemTemp.createTemp(
        'ccpocket_conversation_mirror_old_bridge_test_',
      );
      final isolatedDatabase = ConversationMirrorDatabase(
        databasePath: path.join(
          isolatedDirectory.path,
          ConversationMirrorDatabase.fileName,
        ),
        openDatabase: openFfi,
      );
      final isolatedBridge = _MirrorTestBridge();
      final isolatedService = ConversationMirrorService(
        bridge: isolatedBridge,
        store: ConversationMirrorStore(isolatedDatabase),
        database: isolatedDatabase,
        initialResponseTimeout: const Duration(milliseconds: 20),
      );
      await isolatedService.initialize();
      addTearDown(() async {
        await isolatedService.close();
        isolatedBridge.dispose();
        if (await isolatedDirectory.exists()) {
          await isolatedDirectory.delete(recursive: true);
        }
      });

      final result = await isolatedService.downloadAndWatch(_recentSession);

      expect(result.success, isFalse);
      expect(result.errorCode, 'capability_not_negotiated');
      expect(isolatedService.featureUnsupported, isTrue);
      expect(isolatedBridge.sent.single['type'], 'conversation_mirror_watch');
    },
  );

  test(
    'accepted switches a long provider read to the page-idle deadline',
    () async {
      final isolatedDirectory = await Directory.systemTemp.createTemp(
        'ccpocket_conversation_mirror_accepted_test_',
      );
      final isolatedDatabase = ConversationMirrorDatabase(
        databasePath: path.join(
          isolatedDirectory.path,
          ConversationMirrorDatabase.fileName,
        ),
        openDatabase: openFfi,
      );
      final isolatedBridge = _MirrorTestBridge();
      final isolatedService = ConversationMirrorService(
        bridge: isolatedBridge,
        store: ConversationMirrorStore(isolatedDatabase),
        database: isolatedDatabase,
        initialResponseTimeout: const Duration(milliseconds: 20),
      );
      await isolatedService.initialize();
      addTearDown(() async {
        await isolatedService.close();
        isolatedBridge.dispose();
        if (await isolatedDirectory.exists()) {
          await isolatedDirectory.delete(recursive: true);
        }
      });
      String? requestId;
      isolatedBridge.onSend = (request) {
        requestId = request['requestId'] as String;
        scheduleMicrotask(() {
          isolatedBridge.emit(_event(requestId: requestId!, event: 'accepted'));
        });
      };

      var completed = false;
      final pending = isolatedService.downloadAndWatch(_recentSession).then((
        result,
      ) {
        completed = true;
        return result;
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(completed, isFalse);

      isolatedBridge.emit(
        ConversationMirrorEventMessage(
          event: ConversationMirrorEventKind.error,
          requestId: requestId!,
          bridgeInstanceId: 'bridge-test',
          provider: 'codex',
          providerSessionId: 'provider-session-1',
          errorCode: 'test_complete',
          error: 'finish the long-read test',
        ),
      );
      final result = await pending;
      expect(result.errorCode, 'test_complete');
    },
  );

  test('a failed old-Bridge watch does not poison a later retry', () async {
    bridge.onSend = (request) {
      scheduleMicrotask(() {
        bridge.emit(
          LocalFeatureRequestErrorMessage(
            featureId: 'conversation_mirror',
            ownerSessionId: request['providerSessionId'] as String,
            requestType: request['type'] as String,
            requestId: request['requestId'] as String,
            message: 'unsupported by this Bridge',
            errorCode: 'unsupported_message',
          ),
        );
      });
    };

    final first = await service.downloadAndWatch(_recentSession);
    final second = await service.downloadAndWatch(_recentSession);

    expect(first.success, isFalse);
    expect(second.success, isFalse);
    expect(
      bridge.sent.where(
        (request) => request['type'] == 'conversation_mirror_watch',
      ),
      hasLength(2),
    );
    expect(
      bridge.sent.where(
        (request) => request['type'] == 'conversation_mirror_unwatch',
      ),
      isEmpty,
    );
  });

  test(
    'worktree session sync uses resumeCwd instead of the base path',
    () async {
      const worktreeSession = RecentSession(
        sessionId: 'provider-session-1',
        provider: 'codex',
        firstPrompt: 'worktree',
        created: '2026-07-18T00:00:00Z',
        modified: '2026-07-18T00:00:00Z',
        gitBranch: 'feature/mirror',
        projectPath: '/tmp/project',
        resumeCwd: '/tmp/project-worktrees/feature-mirror',
        isSidechain: false,
      );
      bridge.onSend = (request) {
        scheduleMicrotask(() {
          bridge.emit(
            LocalFeatureRequestErrorMessage(
              featureId: 'conversation_mirror',
              ownerSessionId: request['providerSessionId'] as String,
              requestType: request['type'] as String,
              requestId: request['requestId'] as String,
              message: 'test stop',
              errorCode: 'unsupported_message',
            ),
          );
        });
      };

      await service.downloadAndWatch(worktreeSession);

      expect(
        bridge.sent.single['projectPath'],
        '/tmp/project-worktrees/feature-mirror',
      );
    },
  );

  test('concurrent download taps share one watch request', () async {
    final message = <String, dynamic>{
      'type': 'user_input',
      'text': 'single flight',
      'userMessageUuid': 'codex:user-turn:0',
    };
    final first = service.downloadAndWatch(_recentSession);
    final second = service.downloadAndWatch(_recentSession);
    await _waitUntil(
      () async => bridge.sent
          .where((request) => request['type'] == 'conversation_mirror_watch')
          .isNotEmpty,
    );
    final watchRequests = bridge.sent
        .where((request) => request['type'] == 'conversation_mirror_watch')
        .toList(growable: false);
    expect(watchRequests, hasLength(1));

    _emitSnapshot(
      bridge,
      requestId: watchRequests.single['requestId'] as String,
      revision: _hashText('single-flight-revision'),
      messages: [message],
    );

    expect((await first).success, isTrue);
    expect((await second).success, isTrue);
    expect(
      bridge.sent.where(
        (request) => request['type'] == 'conversation_mirror_unwatch',
      ),
      isEmpty,
    );
  });

  test('running targets keep durable identity and worktree resume path', () {
    const running = SessionInfo(
      id: 'runtime-only-id',
      provider: 'codex',
      projectPath: '/tmp/base-project',
      claudeSessionId: 'durable-thread-id',
      status: 'running',
      createdAt: '2026-07-20T00:00:00Z',
      lastActivityAt: '2026-07-20T00:01:00Z',
      worktreePath: '/tmp/base-project-worktrees/feature',
      worktreeBranch: 'feature/resident',
      lastMessage: 'keep this running chat resident',
      codexModel: 'gpt-5.6',
      codexModelReasoningEffort: 'ultra',
    );

    final target = ConversationMirrorTarget.fromRunning(running)!;
    final recent = target.toRecentSession();

    expect(target.providerSessionId, 'durable-thread-id');
    expect(target.runtimeSessionId, 'runtime-only-id');
    expect(target.effectiveProjectPath, '/tmp/base-project-worktrees/feature');
    expect(recent.sessionId, 'durable-thread-id');
    expect(recent.resumeCwd, '/tmp/base-project-worktrees/feature');
    expect(recent.codexModelReasoningEffort, 'ultra');
  });

  test(
    'same-title conversations remain isolated by durable thread ID',
    () async {
      final first = _recentSessionWithId(
        'thread-same-title-a',
        name: 'Repeated title',
      );
      final second = _recentSessionWithId(
        'thread-same-title-b',
        name: 'Repeated title',
      );
      const firstKey = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-test',
        provider: 'codex',
        providerSessionId: 'thread-same-title-a',
      );
      const secondKey = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-test',
        provider: 'codex',
        providerSessionId: 'thread-same-title-b',
      );
      await _seedLocalCopy(
        store,
        key: firstKey,
        message: const {
          'type': 'user_input',
          'text': 'first conversation',
          'userMessageUuid': 'same-title-a',
        },
        revision: _hashText('same-title-a'),
      );
      await _seedLocalCopy(
        store,
        key: secondKey,
        message: const {
          'type': 'user_input',
          'text': 'second conversation',
          'userMessageUuid': 'same-title-b',
        },
        revision: _hashText('same-title-b'),
      );

      final firstMetadata = await service.metadataFor(first);
      final secondMetadata = await service.metadataFor(second);

      expect(firstMetadata?.key, firstKey);
      expect(secondMetadata?.key, secondKey);
      expect(firstMetadata?.key, isNot(secondMetadata?.key));
    },
  );

  test(
    'paused phone copy can become resident while Bridge is offline',
    () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-test',
        provider: 'codex',
        providerSessionId: 'provider-session-1',
      );
      await _seedLocalCopy(
        store,
        message: const {
          'type': 'user_input',
          'text': 'kept offline',
          'userMessageUuid': 'offline-resident-1',
        },
        revision: _hashText('offline-resident'),
      );
      await store.setAutoSync(key, false, projectPath: '/tmp/project');
      expect((await service.metadataFor(_recentSession))?.autoSync, isFalse);
      bridge.connected = false;

      final result = await service.makeResidentTarget(
        ConversationMirrorTarget.fromRecent(_recentSession),
      );

      expect(result.success, isTrue);
      expect(result.changed, isFalse);
      expect(bridge.sent, isEmpty);
      final metadata = await store.readMetadata(key);
      expect(metadata?.autoSync, isTrue);
      expect(metadata?.hasLocalCopy, isTrue);
      expect(await store.readEntries(key), hasLength(1));
      expect(service.residentMetadata.map((item) => item.key), contains(key));
    },
  );

  test('stopping residency keeps the full phone copy and unwatches', () async {
    final download = service.downloadAndWatch(_recentSession);
    await _waitUntil(() async => bridge.sent.isNotEmpty);
    final requestId = bridge.sent.single['requestId'] as String;
    _emitSnapshot(
      bridge,
      requestId: requestId,
      revision: _hashText('resident-stop'),
      messages: const [
        {
          'type': 'user_input',
          'text': 'keep the copy',
          'userMessageUuid': 'resident-stop-1',
        },
      ],
    );
    expect((await download).success, isTrue);

    await service.stopBeingResident(_recentSession);

    final metadata = await service.metadataFor(_recentSession);
    expect(metadata?.autoSync, isFalse);
    expect(metadata?.hasLocalCopy, isTrue);
    expect(await store.readEntries(metadata!.key), hasLength(1));
    expect(
      bridge.sent.map((message) => message['type']),
      contains('conversation_mirror_unwatch'),
    );
  });

  test('resident watch count is bounded to the Bridge limit', () async {
    for (
      var index = 0;
      index < ConversationMirrorService.maxResidentConversations;
      index++
    ) {
      final id = 'resident-$index';
      final key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-test',
        provider: 'codex',
        providerSessionId: id,
      );
      final session = _recentSessionWithId(id);
      await _seedLocalCopy(
        store,
        key: key,
        message: {
          'type': 'user_input',
          'text': id,
          'userMessageUuid': 'resident-limit-$index',
        },
        revision: _hashText('resident-limit-$index'),
      );
      await service.metadataFor(session);
    }

    final result = await service.downloadAndWatch(
      _recentSessionWithId('resident-ninth'),
    );

    expect(result.success, isFalse);
    expect(result.errorCode, 'resident_limit_reached');
    expect(bridge.sent, isEmpty);
  });

  test(
    'disconnect fails an in-flight download without waiting for timeout',
    () async {
      bridge.onSend = (_) {
        scheduleMicrotask(() {
          bridge.connected = false;
          bridge.emitConnection(BridgeConnectionState.reconnecting);
        });
      };

      final result = await service.downloadAndWatch(_recentSession);

      expect(result.success, isFalse);
      expect(result.errorCode, 'bridge_disconnected');
      expect(service.isSyncing(_recentSession), isFalse);
    },
  );

  test(
    'remove cancels a pre-accept watch and ignores its late snapshot',
    () async {
      late String requestId;
      bridge.onSend = (request) {
        if (request['type'] == 'conversation_mirror_watch') {
          requestId = request['requestId'] as String;
        }
      };

      final download = service.downloadAndWatch(_recentSession);
      await _waitUntil(() async => bridge.sent.isNotEmpty);
      await service.removeLocalCopy(_recentSession);
      final result = await download;

      expect(result.success, isFalse);
      expect(result.errorCode, 'local_copy_removed');
      expect(bridge.sent.map((request) => request['type']), [
        'conversation_mirror_watch',
        'conversation_mirror_unwatch',
      ]);

      final message = <String, dynamic>{
        'type': 'user_input',
        'text': 'late snapshot',
        'userMessageUuid': 'codex:user-turn:0',
      };
      final revision = _hashText('late-revision');
      bridge
        ..emit(
          _event(
            requestId: requestId,
            event: 'snapshot_begin',
            revision: revision,
            entryCount: 1,
            pageCount: 1,
            totalBytes: utf8.encode(jsonEncode(message)).length,
          ),
        )
        ..emit(
          _event(
            requestId: requestId,
            event: 'snapshot_page',
            revision: revision,
            pageIndex: 0,
            pageCount: 1,
            entries: [
              {
                'entryId': 'late-user',
                'index': 0,
                'contentHash': _hashJson(message),
                'message': message,
              },
            ],
          ),
        )
        ..emit(
          _event(
            requestId: requestId,
            event: 'snapshot_complete',
            revision: revision,
            entryCount: 1,
          ),
        );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await service.metadataFor(_recentSession), isNull);
    },
  );

  test(
    'manual refresh reconciles even when an auto-watch already exists',
    () async {
      final message = <String, dynamic>{
        'type': 'user_input',
        'text': 'cached',
        'userMessageUuid': 'codex:user-turn:0',
      };
      final revision = _hashText('cached-revision');
      await _seedLocalCopy(store, message: message, revision: revision);
      await service.metadataFor(_recentSession);

      bridge.onSend = (request) {
        final requestId = request['requestId'] as String;
        scheduleMicrotask(() {
          if (request['type'] == 'conversation_mirror_watch') {
            bridge.emit(
              _event(
                requestId: requestId,
                event: 'watching',
                revision: revision,
                threadStatus: 'idle',
              ),
            );
          }
          bridge.emit(
            _event(
              requestId: requestId,
              event: 'not_modified',
              revision: revision,
              threadStatus: 'idle',
            ),
          );
        });
      };

      final first = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );
      final forced = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
        force: true,
      );

      expect(first, isTrue);
      expect(forced, isTrue);
      expect(bridge.sent.map((request) => request['type']), [
        'conversation_mirror_watch',
        'conversation_mirror_sync',
      ]);
      expect(bridge.sent.last['knownRevision'], revision);
    },
  );

  test(
    'bounded background reconcile never restores a missing resident watch',
    () async {
      final revision = _hashText('background-resident');
      await _seedLocalCopy(
        store,
        message: const {
          'type': 'user_input',
          'text': 'resident cache',
          'userMessageUuid': 'codex:user-turn:0',
        },
        revision: revision,
      );
      await service.metadataFor(_recentSession);

      final backgroundCount = await service.reconcileResidents(
        maximumConversations: 2,
        budget: const Duration(seconds: 1),
        restoreMissingWatches: false,
      );

      expect(backgroundCount, 0);
      expect(bridge.sent, isEmpty);

      bridge.onSend = (request) {
        final requestId = request['requestId'] as String;
        scheduleMicrotask(() {
          bridge
            ..emit(
              _event(
                requestId: requestId,
                event: 'watching',
                revision: revision,
                threadStatus: 'idle',
              ),
            )
            ..emit(
              _event(
                requestId: requestId,
                event: 'not_modified',
                revision: revision,
                threadStatus: 'idle',
              ),
            );
        });
      };

      final foregroundCount = await service.reconcileResidents(
        maximumConversations: 2,
        budget: const Duration(seconds: 1),
        restoreMissingWatches: true,
      );

      expect(foregroundCount, 1);
      expect(bridge.sent.single['type'], 'conversation_mirror_watch');
      expect(bridge.sent.single['knownRevision'], revision);
    },
  );

  test('background cancellation releases an in-flight resident sync', () async {
    final revision = _hashText('cancelled-background-resident');
    await _seedLocalCopy(
      store,
      message: const {
        'type': 'user_input',
        'text': 'resident cache',
        'userMessageUuid': 'codex:user-turn:0',
      },
      revision: revision,
    );
    await service.metadataFor(_recentSession);
    bridge.onSend = (request) {
      final requestId = request['requestId'] as String;
      scheduleMicrotask(() {
        bridge
          ..emit(
            _event(
              requestId: requestId,
              event: 'watching',
              revision: revision,
              threadStatus: 'idle',
            ),
          )
          ..emit(
            _event(
              requestId: requestId,
              event: 'not_modified',
              revision: revision,
              threadStatus: 'idle',
            ),
          );
      });
    };
    expect(
      await service.reconcileResidents(
        maximumConversations: 1,
        budget: const Duration(seconds: 1),
        restoreMissingWatches: true,
      ),
      1,
    );

    bridge
      ..sent.clear()
      ..onSend = (_) {};
    final cancellation = _TestMirrorCancellation();
    final reconciliation = service.reconcileResidents(
      maximumConversations: 1,
      budget: const Duration(seconds: 10),
      restoreMissingWatches: false,
      cancellation: cancellation,
    );
    await _waitUntil(
      () async => bridge.sent.any(
        (request) => request['type'] == 'conversation_mirror_sync',
      ),
    );

    cancellation.cancel();

    expect(await reconciliation.timeout(const Duration(milliseconds: 200)), 0);
    expect(service.isSyncing(_recentSession), isFalse);

    bridge.sent.clear();
    final budgetedReconciliation = service.reconcileResidents(
      maximumConversations: 1,
      budget: const Duration(milliseconds: 20),
      restoreMissingWatches: false,
    );
    await _waitUntil(
      () async => bridge.sent.any(
        (request) => request['type'] == 'conversation_mirror_sync',
      ),
    );
    final budgetRequestId = bridge.sent.single['requestId'] as String;

    expect(
      await budgetedReconciliation.timeout(
        const Duration(milliseconds: 200),
      ),
      0,
    );
    expect(service.isSyncing(_recentSession), isFalse);

    bridge.emit(
      _event(
        requestId: budgetRequestId,
        event: 'snapshot_begin',
        revision: _hashText('late-after-budget'),
        entryCount: 1,
        pageCount: 1,
        totalBytes: 16,
        threadStatus: 'idle',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await service.metadataFor(_recentSession))?.revision, revision);
  });

  test(
    'background reconnect defers automatic resident watch restoration',
    () async {
      final revision = _hashText('deferred-background-watch');
      await _seedLocalCopy(
        store,
        message: const {
          'type': 'user_input',
          'text': 'resident cache',
          'userMessageUuid': 'codex:user-turn:0',
        },
        revision: revision,
      );
      await service.metadataFor(_recentSession);
      await service.setAutomaticWatchRestorationEnabled(false);

      bridge
        ..connected = false
        ..emitConnection(BridgeConnectionState.disconnected)
        ..connected = true
        ..emitConnection(BridgeConnectionState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bridge.sent, isEmpty);

      await service.setAutomaticWatchRestorationEnabled(true);
      await _waitUntil(() async => bridge.sent.isNotEmpty);

      expect(bridge.sent.single['type'], 'conversation_mirror_watch');
      expect(bridge.sent.single['knownRevision'], revision);
    },
  );

  test(
    'not-modified sync restores an invalidated full-history cursor',
    () async {
      final revision = _hashText('not-modified-cursor-rebind');
      await _seedLocalConversation(
        store,
        entryCount: 3000,
        revision: revision,
      );
      await service.metadataFor(_recentSession);
      bridge.connected = false;

      expect(
        await bridge.tryBootstrapSessionHistory(
          runtimeSessionId: 'runtime-1',
          provider: 'codex',
          projectPath: '/tmp/project',
        ),
        isTrue,
      );
      expect(bridge.hasLocalSessionHistory('runtime-1'), isTrue);

      final availability = <LocalSessionHistoryAvailabilityChange>[];
      final subscription = bridge.sessionHistoryAvailabilityChanges.listen(
        availability.add,
      );
      addTearDown(subscription.cancel);
      bridge.invalidateLocalSessionHistoryPaging('runtime-1');
      expect(bridge.hasLocalSessionHistory('runtime-1'), isFalse);

      bridge
        ..connected = true
        ..onSend = (request) {
          if (request['type'] != 'conversation_mirror_sync') return;
          final requestId = request['requestId'] as String;
          scheduleMicrotask(() {
            bridge
              ..emit(
                _event(
                  requestId: requestId,
                  event: 'accepted',
                  revision: revision,
                  threadStatus: 'idle',
                ),
              )
              ..emit(
                _event(
                  requestId: requestId,
                  event: 'not_modified',
                  revision: revision,
                  threadStatus: 'idle',
                ),
              );
          });
        };

      final result = await service.syncNow(_recentSession);

      expect(result.success, isTrue);
      expect(result.changed, isFalse);
      expect(bridge.hasLocalSessionHistory('runtime-1'), isTrue);
      expect(
        await bridge.tryLoadLocalSessionUserIndex(
          runtimeSessionId: 'runtime-1',
        ),
        hasLength(3000),
      );
      expect(
        availability.map((event) => event.available),
        containsAllInOrder([false, true]),
      );
    },
  );

  test('not-modified sync preserves an advanced paging cursor', () async {
    final revision = _hashText('not-modified-preserves-offset');
    await _seedLocalConversation(store, entryCount: 600, revision: revision);
    await service.metadataFor(_recentSession);
    bridge.connected = false;
    expect(
      await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      ),
      isTrue,
    );
    final firstPage = await bridge.tryLoadOlderLocalSessionHistory(
      runtimeSessionId: 'runtime-1',
    );
    expect((firstPage!.messages.first as UserInputMessage).text, 'message-200');
    expect((firstPage.messages.last as UserInputMessage).text, 'message-399');

    bridge
      ..connected = true
      ..onSend = (request) {
        if (request['type'] != 'conversation_mirror_sync') return;
        final requestId = request['requestId'] as String;
        scheduleMicrotask(() {
          bridge
            ..emit(
              _event(
                requestId: requestId,
                event: 'accepted',
                revision: revision,
                threadStatus: 'idle',
              ),
            )
            ..emit(
              _event(
                requestId: requestId,
                event: 'not_modified',
                revision: revision,
                threadStatus: 'idle',
              ),
            );
        });
      };

    expect((await service.syncNow(_recentSession)).success, isTrue);
    final secondPage = await bridge.tryLoadOlderLocalSessionHistory(
      runtimeSessionId: 'runtime-1',
    );
    expect((secondPage!.messages.first as UserInputMessage).text, 'message-0');
    expect((secondPage.messages.last as UserInputMessage).text, 'message-199');
    expect(secondPage.hasMore, isFalse);
  });

  test(
    'canonical mutation during local read preserves local paging while reconciling the live tail',
    () async {
      final message = <String, dynamic>{
        'type': 'user_input',
        'text': 'cached before live update',
        'userMessageUuid': 'codex:user-turn:0',
      };
      await _seedLocalCopy(
        store,
        message: message,
        revision: _hashText('race-revision'),
      );
      await service.metadataFor(_recentSession);
      store
        ..readStarted = Completer<void>()
        ..readGate = Completer<void>();
      bridge.connected = false;

      final bootstrap = bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );
      await store.readStarted!.future;
      bridge.contentEpoch += 1;
      store.readGate!.complete();

      expect(await bootstrap, isTrue);
      expect(bridge.externallyPublishedHistories, isEmpty);
      expect(bridge.hasLocalSessionHistory('runtime-1'), isTrue);
      expect(
        await bridge.tryLoadLocalSessionUserIndex(
          runtimeSessionId: 'runtime-1',
        ),
        hasLength(1),
      );
      expect(bridge.sent.map((request) => request['type']), ['get_history']);
    },
  );

  test(
    'a content race aligns the next local page directly before the bounded canonical tail',
    () async {
      final revision = _hashText('race-aligns-canonical-tail');
      await _seedLocalConversation(store, entryCount: 600, revision: revision);
      await service.metadataFor(_recentSession);
      bridge
        ..connected = false
        ..canonicalMessages = List.generate(
          50,
          (index) {
            final ordinal = index + 550;
            return UserInputMessage(
              text: 'message-$ordinal',
              userMessageUuid: 'codex:user-turn:$ordinal',
            );
          },
        );
      store
        ..readStarted = Completer<void>()
        ..readGate = Completer<void>();

      final bootstrap = bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );
      await store.readStarted!.future;
      bridge.contentEpoch += 1;
      store.readGate!.complete();

      expect(await bootstrap, isTrue);
      final older = await bridge.tryLoadOlderLocalSessionHistory(
        runtimeSessionId: 'runtime-1',
      );
      expect(older, isNotNull);
      expect(older!.messages, hasLength(200));
      expect((older.messages.first as UserInputMessage).text, 'message-350');
      expect((older.messages.last as UserInputMessage).text, 'message-549');
    },
  );

  test(
    'a 3000-entry local copy publishes only the recent window and pages older entries',
    () async {
      await _seedLocalConversation(
        store,
        entryCount: 3000,
        revision: _hashText('paged-3000-entry-history'),
      );
      bridge.connected = false;

      final handled = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );

      expect(handled, isTrue);
      expect(bridge.externallyPublishedHistories, hasLength(1));
      final initial = bridge.externallyPublishedHistories.single;
      expect(initial, hasLength(200));
      expect((initial.first as UserInputMessage).text, 'message-2800');
      expect((initial.last as UserInputMessage).text, 'message-2999');
      expect(bridge.hasOlderLocalSessionHistory('runtime-1'), isTrue);

      final loaded = <ServerMessage>[...initial];
      while (bridge.hasOlderLocalSessionHistory('runtime-1')) {
        final page = await bridge.tryLoadOlderLocalSessionHistory(
          runtimeSessionId: 'runtime-1',
        );
        expect(page, isNotNull);
        loaded.insertAll(0, page!.messages);
      }

      expect(loaded, hasLength(3000));
      expect((loaded.first as UserInputMessage).text, 'message-0');
      expect((loaded.last as UserInputMessage).text, 'message-2999');
      expect(
        loaded.whereType<UserInputMessage>().map((message) => message.text),
        orderedEquals(List.generate(3000, (index) => 'message-$index')),
      );
    },
  );

  test(
    'a distant turn loads one 200-entry target window and resets older paging',
    () async {
      await _seedLocalConversation(
        store,
        entryCount: 3000,
        revision: _hashText('target-window-3000-entry-history'),
      );
      bridge.connected = false;

      expect(
        await bridge.tryBootstrapSessionHistory(
          runtimeSessionId: 'runtime-1',
          provider: 'codex',
          projectPath: '/tmp/project',
        ),
        isTrue,
      );
      final index = await bridge.tryLoadLocalSessionUserIndex(
        runtimeSessionId: 'runtime-1',
      );
      expect(index, hasLength(3000));
      expect(index![100].ordinal, 100);
      expect(index[100].message.text, 'message-100');

      final targetWindow = await bridge.tryLoadLocalSessionHistoryWindow(
        runtimeSessionId: 'runtime-1',
        startOrdinal: index[100].ordinal,
      );

      expect(targetWindow, isNotNull);
      expect(targetWindow!.messages, hasLength(200));
      expect(
        (targetWindow.messages.first as UserInputMessage).text,
        'message-100',
      );
      expect(
        (targetWindow.messages.last as UserInputMessage).text,
        'message-299',
      );
      expect(targetWindow.hasMore, isTrue);

      final older = await bridge.tryLoadOlderLocalSessionHistory(
        runtimeSessionId: 'runtime-1',
      );
      expect(older, isNotNull);
      expect(older!.messages, hasLength(100));
      expect((older.messages.first as UserInputMessage).text, 'message-0');
      expect((older.messages.last as UserInputMessage).text, 'message-99');
      expect(older.hasMore, isFalse);
    },
  );

  test(
    'a bounded canonical cache keeps the complete local mirror pageable',
    () async {
      await _seedLocalConversation(
        store,
        entryCount: 3000,
        revision: _hashText('paged-history-with-canonical-cache'),
      );
      bridge
        ..connected = false
        ..canonicalMessages = const [
          UserInputMessage(
            text: 'new Desktop turn',
            userMessageUuid: 'codex:user-turn:3000',
          ),
        ];

      final handled = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );

      expect(handled, isTrue);
      expect(bridge.externallyPublishedHistories, hasLength(1));
      final initial = bridge.externallyPublishedHistories.single;
      expect(initial, hasLength(201));
      expect((initial.first as UserInputMessage).text, 'message-2800');
      expect((initial.last as UserInputMessage).text, 'new Desktop turn');
      expect(bridge.hasOlderLocalSessionHistory('runtime-1'), isTrue);

      var loadedCount = initial.length;
      while (bridge.hasOlderLocalSessionHistory('runtime-1')) {
        final page = await bridge.tryLoadOlderLocalSessionHistory(
          runtimeSessionId: 'runtime-1',
        );
        expect(page, isNotNull);
        loadedCount += page!.messages.length;
      }
      expect(loadedCount, 3001);
    },
  );

  test(
    'canonical overlap replaces rather than duplicates a mirror envelope',
    () async {
      await _seedLocalConversation(
        store,
        entryCount: 300,
        revision: _hashText('paged-history-canonical-overlap'),
      );
      bridge
        ..connected = false
        ..canonicalMessages = const [
          UserInputMessage(
            text: 'canonical message 299',
            userMessageUuid: 'codex:user-turn:299',
          ),
          UserInputMessage(
            text: 'canonical message 300',
            userMessageUuid: 'codex:user-turn:300',
          ),
        ];

      expect(
        await bridge.tryBootstrapSessionHistory(
          runtimeSessionId: 'runtime-1',
          provider: 'codex',
          projectPath: '/tmp/project',
        ),
        isTrue,
      );

      final initial = bridge.externallyPublishedHistories.single;
      expect(initial, hasLength(201));
      expect(
        initial.whereType<UserInputMessage>().where(
          (message) => message.userMessageUuid == 'codex:user-turn:299',
        ),
        hasLength(1),
      );
      expect((initial[199] as UserInputMessage).text, 'canonical message 299');
      expect((initial.last as UserInputMessage).text, 'canonical message 300');
    },
  );

  test(
    'a superseded page read cannot remove the replacement mirror cursor',
    () async {
      await _seedLocalConversation(
        store,
        entryCount: 600,
        revision: _hashText('paged-revision-one'),
      );
      bridge.connected = false;
      expect(
        await bridge.tryBootstrapSessionHistory(
          runtimeSessionId: 'runtime-1',
          provider: 'codex',
          projectPath: '/tmp/project',
        ),
        isTrue,
      );

      final staleReadGate = Completer<void>();
      store
        ..readStarted = Completer<void>()
        ..readGate = staleReadGate;
      final stalePage = bridge.tryLoadOlderLocalSessionHistory(
        runtimeSessionId: 'runtime-1',
      );
      await store.readStarted!.future;

      // The old read has already captured this gate. New snapshot reads can
      // now proceed and install a replacement cursor for the same runtime.
      store.readGate = null;
      await _seedLocalConversation(
        store,
        entryCount: 600,
        revision: _hashText('paged-revision-two'),
      );
      expect(
        await bridge.tryBootstrapSessionHistory(
          runtimeSessionId: 'runtime-1',
          provider: 'codex',
          projectPath: '/tmp/project',
          force: true,
        ),
        isTrue,
      );

      staleReadGate.complete();
      expect(await stalePage, isNull);
      expect(bridge.hasOlderLocalSessionHistory('runtime-1'), isTrue);

      final replacementPage = await bridge.tryLoadOlderLocalSessionHistory(
        runtimeSessionId: 'runtime-1',
      );
      expect(replacementPage, isNotNull);
      expect(replacementPage!.messages, hasLength(200));
      expect(
        (replacementPage.messages.first as UserInputMessage).text,
        'message-200',
      );
    },
  );

  test(
    'a page that starts mid-turn carries the preceding user timestamp',
    () async {
      await _seedLocalConversation(
        store,
        entryCount: 401,
        revision: _hashText('paged-timestamp-anchor'),
        messageBuilder: (index) {
          if (index == 200) {
            return {
              'type': 'user_input',
              'text': 'turn anchor',
              'timestamp': '2026-01-02T03:04:05.000Z',
              'userMessageUuid': 'codex:user-turn:$index',
            };
          }
          if (index > 200) {
            return {
              'type': 'assistant',
              'messageUuid': 'assistant-$index',
              'message': {
                'id': 'assistant-$index',
                'role': 'assistant',
                'model': 'codex',
                'content': [
                  {'type': 'text', 'text': 'assistant-$index'},
                ],
              },
            };
          }
          return {
            'type': 'user_input',
            'text': 'message-$index',
            'userMessageUuid': 'codex:user-turn:$index',
          };
        },
      );
      bridge.connected = false;

      expect(
        await bridge.tryBootstrapSessionHistory(
          runtimeSessionId: 'runtime-1',
          provider: 'codex',
          projectPath: '/tmp/project',
        ),
        isTrue,
      );
      expect(
        bridge.externallyPublishedTimestampAnchors.single,
        DateTime.parse('2026-01-02T03:04:05.000Z').toLocal(),
      );
    },
  );

  test(
    'downloaded tool details remain available from the mirror while offline',
    () async {
      await _seedLocalConversation(
        store,
        entryCount: 4,
        revision: _hashText('offline-tool-detail'),
        messageBuilder: (index) => switch (index) {
          0 => {
            'type': 'user_input',
            'text': 'read the local file',
            'userMessageUuid': 'codex:user-turn:0',
          },
          1 => {
            'type': 'assistant',
            'messageUuid': 'assistant-tools',
            'message': {
              'id': 'assistant-tools',
              'role': 'assistant',
              'model': 'codex',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'tool-read',
                  'name': 'Read',
                  'input': {'file_path': '/tmp/local.txt'},
                },
                {
                  'type': 'tool_use',
                  'id': 'tool-unrelated',
                  'name': 'Search',
                  'input': {'query': 'not requested'},
                },
              ],
            },
          },
          2 => {
            'type': 'tool_result',
            'toolUseId': 'tool-read',
            'toolName': 'Read',
            'content': 'local contents',
          },
          _ => {
            'type': 'tool_result',
            'toolUseId': 'tool-unrelated',
            'toolName': 'Search',
            'content': 'unrelated contents',
          },
        },
      );
      bridge.connected = false;

      expect(
        await bridge.tryBootstrapSessionHistory(
          runtimeSessionId: 'runtime-1',
          provider: 'codex',
          projectPath: '/tmp/project',
        ),
        isTrue,
      );

      final details = await bridge.requestHistoryToolDetails(
        runtimeSessionId: 'runtime-1',
        toolUseIds: const ['tool-read', 'missing'],
      );

      expect(details, hasLength(1));
      expect(details?.single.toolUseId, 'tool-read');
      expect(details?.single.toolName, 'Read');
      expect(details?.single.input, {'file_path': '/tmp/local.txt'});
      expect(details?.single.result?.content, 'local contents');
      expect(bridge.sent, isEmpty);
    },
  );

  test(
    'canonical mutation after local decode keeps the full index without publishing stale content',
    () async {
      final message = <String, dynamic>{
        'type': 'user_input',
        'text': 'cached before decode race',
        'userMessageUuid': 'codex:user-turn:0',
      };
      await _seedLocalCopy(
        store,
        message: message,
        revision: _hashText('decode-race-revision'),
      );
      await service.metadataFor(_recentSession);
      var epochReads = 0;
      bridge.onReadContentEpoch = () {
        epochReads += 1;
        return epochReads <= 1 ? 0 : 1;
      };
      bridge.connected = false;
      final published = <ServerMessage>[];
      final subscription = bridge
          .messagesForSession('runtime-1')
          .listen(published.add);
      addTearDown(subscription.cancel);

      final handled = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );
      await Future<void>.delayed(Duration.zero);

      expect(handled, isTrue);
      expect(published.whereType<HistoryMessage>(), isEmpty);
      expect(bridge.hasLocalSessionHistory('runtime-1'), isTrue);
      expect(
        await bridge.tryLoadLocalSessionUserIndex(
          runtimeSessionId: 'runtime-1',
        ),
        hasLength(1),
      );
      expect(bridge.sent.map((request) => request['type']), ['get_history']);
    },
  );

  test(
    'preexisting canonical content wins over an older local mirror with the same id',
    () async {
      final localMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'old local text',
        'userMessageUuid': 'shared-user-id',
      };
      await _seedLocalCopy(
        store,
        message: localMessage,
        revision: _hashText('preexisting-canonical-revision'),
      );
      await service.metadataFor(_recentSession);
      bridge
        ..connected = false
        ..canonicalMessages = const [
          UserInputMessage(
            text: 'new canonical text',
            userMessageUuid: 'shared-user-id',
          ),
        ];

      final handled = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );

      expect(handled, isTrue);
      expect(bridge.externallyPublishedHistories, hasLength(1));
      final published = bridge.externallyPublishedHistories.single;
      expect(published, hasLength(1));
      expect((published.single as UserInputMessage).text, 'new canonical text');
      expect(bridge.hasOlderLocalSessionHistory('runtime-1'), isFalse);
      expect(bridge.sent, isEmpty);
    },
  );

  test(
    'established watch keeps newer canonical same-id content during a mirror patch',
    () async {
      final initialMessage = <String, dynamic>{
        'type': 'assistant',
        'messageUuid': 'shared-assistant-uuid',
        'message': {
          'id': 'shared-assistant-id',
          'role': 'assistant',
          'model': 'codex',
          'content': [
            {'type': 'text', 'text': 'mirror before'},
          ],
        },
      };
      final initialRevision = _hashText('accepted-epoch-r1');
      final download = service.downloadAndWatch(_recentSession);
      await _waitUntil(() async => bridge.sent.isNotEmpty);
      final requestId = bridge.sent.single['requestId'] as String;
      _emitSnapshot(
        bridge,
        requestId: requestId,
        revision: initialRevision,
        messages: [initialMessage],
      );
      expect((await download).success, isTrue);
      await _waitUntil(
        () async =>
            (await service.metadataFor(_recentSession))?.revision ==
            initialRevision,
      );
      bridge
        ..externallyPublishedHistories.clear()
        ..sent.clear();
      store
        ..readStarted = Completer<void>()
        ..readGate = Completer<void>();

      final staleMirrorMessage = <String, dynamic>{
        'type': 'assistant',
        'messageUuid': 'shared-assistant-uuid',
        'message': {
          'id': 'shared-assistant-id',
          'role': 'assistant',
          'model': 'codex',
          'content': [
            {'type': 'text', 'text': 'stale mirror replacement'},
          ],
        },
      };
      final nextRevision = _hashText('accepted-epoch-r2');
      final patchHandled = Completer<void>();
      void completeWhenHandled() {
        if (service.cachedMetadataFor(_recentSession)?.revision ==
                nextRevision &&
            !patchHandled.isCompleted) {
          patchHandled.complete();
        }
      }

      service.addListener(completeWhenHandled);
      addTearDown(() => service.removeListener(completeWhenHandled));
      bridge
        ..emit(_event(requestId: requestId, event: 'accepted'))
        ..emit(
          _event(
            requestId: requestId,
            event: 'patch',
            revision: nextRevision,
            baseRevision: initialRevision,
            upserts: [
              {
                'entryId': 'entry-0',
                'index': 0,
                'contentHash': _hashJson(staleMirrorMessage),
                'message': staleMirrorMessage,
              },
            ],
            deletes: const [],
          ),
        );
      await store.readStarted!.future;
      bridge
        ..canonicalMessages = const [
          AssistantServerMessage(
            messageUuid: 'shared-assistant-uuid',
            message: AssistantMessage(
              id: 'shared-assistant-id',
              role: 'assistant',
              model: 'codex',
              content: [TextContent(text: 'new canonical replacement')],
            ),
          ),
        ]
        ..contentEpoch += 1;
      store.readGate!.complete();
      await patchHandled.future;
      expect(bridge.externallyPublishedHistories, isEmpty);
      expect(
        bridge.sent.where((request) => request['type'] == 'get_history'),
        hasLength(1),
      );
      final stored = await store.readEntries(
        const ConversationMirrorKey(
          bridgeInstanceId: 'bridge-test',
          provider: 'codex',
          providerSessionId: 'provider-session-1',
        ),
      );
      expect(
        (stored.single.message['message'] as Map<String, dynamic>)['content'],
        [
          {'type': 'text', 'text': 'stale mirror replacement'},
        ],
      );
    },
  );

  test(
    'older mirror Bridge patch stores locally but converges active runtime canonically',
    () async {
      final initialMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'transition bridge before',
        'userMessageUuid': 'transition-user',
      };
      final initialRevision = _hashText('transition-r1');
      final download = service.downloadAndWatch(_recentSession);
      await _waitUntil(() async => bridge.sent.isNotEmpty);
      final requestId = bridge.sent.single['requestId'] as String;
      _emitSnapshot(
        bridge,
        requestId: requestId,
        revision: initialRevision,
        messages: [initialMessage],
      );
      expect((await download).success, isTrue);
      bridge
        ..externallyPublishedHistories.clear()
        ..sent.clear();

      final transitionMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'transition bridge patch',
        'userMessageUuid': 'transition-user',
      };
      final transitionRevision = _hashText('transition-r2');
      final patchHandled = Completer<void>();
      void completeWhenHandled() {
        if (service.cachedMetadataFor(_recentSession)?.revision ==
                transitionRevision &&
            !patchHandled.isCompleted) {
          patchHandled.complete();
        }
      }

      service.addListener(completeWhenHandled);
      addTearDown(() => service.removeListener(completeWhenHandled));

      // No repeated accepted: this models the short-lived mirror-capable
      // Bridge version that predates provider-read transfer boundaries.
      bridge.emit(
        _event(
          requestId: requestId,
          event: 'patch',
          revision: transitionRevision,
          baseRevision: initialRevision,
          upserts: [
            {
              'entryId': 'entry-0',
              'index': 0,
              'contentHash': _hashJson(transitionMessage),
              'message': transitionMessage,
            },
          ],
          deletes: const [],
        ),
      );
      await patchHandled.future;

      expect(bridge.externallyPublishedHistories, isEmpty);
      expect(
        bridge.sent.where((request) => request['type'] == 'get_history'),
        hasLength(1),
      );
      final stored = await store.readEntries(
        const ConversationMirrorKey(
          bridgeInstanceId: 'bridge-test',
          provider: 'codex',
          providerSessionId: 'provider-session-1',
        ),
      );
      expect(stored.single.message['text'], 'transition bridge patch');
    },
  );

  test(
    'rebound runtime rejects an old transfer and accepts the next guarded patch',
    () async {
      final initialMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'before rebind',
        'userMessageUuid': 'rebind-user',
      };
      final initialRevision = _hashText('rebind-r1');
      final download = service.downloadAndWatch(_recentSession);
      await _waitUntil(() async => bridge.sent.isNotEmpty);
      final requestId = bridge.sent.single['requestId'] as String;
      _emitSnapshot(
        bridge,
        requestId: requestId,
        revision: initialRevision,
        messages: [initialMessage],
      );
      expect((await download).success, isTrue);
      bridge
        ..externallyPublishedHistories.clear()
        ..sent.clear();
      store
        ..readStarted = Completer<void>()
        ..readGate = Completer<void>();

      final reboundMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'must not enter rebound runtime',
        'userMessageUuid': 'rebind-user',
      };
      final reboundRevision = _hashText('rebind-r2');
      final reboundHandled = Completer<void>();
      final finalHandled = Completer<void>();
      String? finalRevision;
      void completeWhenHandled() {
        final revision = service.cachedMetadataFor(_recentSession)?.revision;
        if (revision == reboundRevision && !reboundHandled.isCompleted) {
          reboundHandled.complete();
        }
        if (revision == finalRevision &&
            finalRevision != null &&
            !finalHandled.isCompleted) {
          finalHandled.complete();
        }
      }

      service.addListener(completeWhenHandled);
      addTearDown(() => service.removeListener(completeWhenHandled));
      bridge
        ..emit(_event(requestId: requestId, event: 'accepted'))
        ..emit(
          _event(
            requestId: requestId,
            event: 'patch',
            revision: reboundRevision,
            baseRevision: initialRevision,
            upserts: [
              {
                'entryId': 'entry-0',
                'index': 0,
                'contentHash': _hashJson(reboundMessage),
                'message': reboundMessage,
              },
            ],
            deletes: const [],
          ),
        );
      await store.readStarted!.future;
      bridge.runtimeProviderSessionId = 'different-provider-session';
      store.readGate!.complete();
      await reboundHandled.future;
      expect(bridge.externallyPublishedHistories, isEmpty);
      expect(
        bridge.sent.where((request) => request['type'] == 'get_history'),
        isEmpty,
      );

      bridge.runtimeProviderSessionId = 'provider-session-1';
      store
        ..readStarted = null
        ..readGate = null;
      final finalMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'next guarded patch',
        'userMessageUuid': 'rebind-user',
      };
      finalRevision = _hashText('rebind-r3');
      bridge
        ..emit(_event(requestId: requestId, event: 'accepted'))
        ..emit(
          _event(
            requestId: requestId,
            event: 'patch',
            revision: finalRevision,
            baseRevision: reboundRevision,
            upserts: [
              {
                'entryId': 'entry-0',
                'index': 0,
                'contentHash': _hashJson(finalMessage),
                'message': finalMessage,
              },
            ],
            deletes: const [],
          ),
        );
      await finalHandled.future;
      expect(bridge.externallyPublishedHistories, hasLength(1));
      expect(
        bridge.externallyPublishedHistories.single
            .whereType<UserInputMessage>()
            .single
            .text,
        'next guarded patch',
      );
    },
  );

  test(
    'closing during a local read prevents a late history publication',
    () async {
      final localMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'must not publish after close',
        'userMessageUuid': 'close-race-user',
      };
      await _seedLocalCopy(
        store,
        message: localMessage,
        revision: _hashText('close-race-revision'),
      );
      await service.metadataFor(_recentSession);
      store
        ..readStarted = Completer<void>()
        ..readGate = Completer<void>();

      final bootstrap = bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );
      await store.readStarted!.future;
      final closing = service.close();
      store.readGate!.complete();

      expect(await bootstrap, isFalse);
      await closing;
      expect(bridge.externallyPublishedHistories, isEmpty);
    },
  );

  test(
    'future v1 envelopes stay stored but are not rendered as errors',
    () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-test',
        provider: 'codex',
        providerSessionId: 'provider-session-1',
      );
      final knownUser = <String, dynamic>{
        'type': 'user_input',
        'text': 'known before',
        'userMessageUuid': 'codex:user-turn:0',
      };
      final futureEnvelope = <String, dynamic>{
        'type': 'future_server_message_v2',
        'futurePayload': true,
      };
      final knownTool = <String, dynamic>{
        'type': 'tool_result',
        'toolUseId': 'tool-1',
        'content': 'known after',
      };
      final rawMessages = [knownUser, futureEnvelope, knownTool];
      await store.beginShadowGeneration(
        key: key,
        generation: 'future-envelope-generation',
        revision: _hashText('future-envelope-revision'),
        entryCount: rawMessages.length,
        pageCount: 1,
        totalBytes: rawMessages.fold<int>(
          0,
          (total, message) => total + utf8.encode(jsonEncode(message)).length,
        ),
        autoSync: true,
        projectPath: '/tmp/project',
      );
      await store.appendShadowPage(
        key: key,
        generation: 'future-envelope-generation',
        pageIndex: 0,
        pageCount: 1,
        entries: [
          for (var index = 0; index < rawMessages.length; index++)
            ConversationMirrorEntryInput(
              entryId: 'future-entry-$index',
              ordinal: index,
              contentHash: _hashJson(rawMessages[index]),
              message: rawMessages[index],
            ),
        ],
      );
      await store.completeShadowGeneration(
        key: key,
        generation: 'future-envelope-generation',
        revision: _hashText('future-envelope-revision'),
        entryCount: rawMessages.length,
      );
      await service.metadataFor(_recentSession);
      bridge.connected = false;
      final published = bridge
          .messagesForSession('runtime-1')
          .where((message) => message is HistoryMessage)
          .cast<HistoryMessage>()
          .first;

      final handled = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );
      final history = await published;

      expect(handled, isTrue);
      expect(history.messages, hasLength(2));
      expect(history.messages.whereType<ErrorMessage>(), isEmpty);
      expect(
        history.messages.whereType<UserInputMessage>().single.text,
        'known before',
      );
      expect(
        history.messages.whereType<ToolResultMessage>().single.content,
        'known after',
      );
      expect((await store.readEntries(key)), hasLength(3));
    },
  );

  test(
    'bootstrap can publish one unambiguous copy without a Bridge id',
    () async {
      final message = <String, dynamic>{
        'type': 'user_input',
        'text': 'available offline',
        'userMessageUuid': 'codex:user-turn:0',
      };
      await _seedLocalCopy(
        store,
        message: message,
        revision: _hashText('offline-revision'),
      );
      final databasePath = await database.resolvedPath;
      await service.close();
      bridge.dispose();

      database = ConversationMirrorDatabase(
        databasePath: databasePath,
        openDatabase: openFfi,
      );
      store = _GateableMirrorStore(database);
      bridge = _MirrorTestBridge()
        ..bridgeId = null
        ..connected = false;
      service = ConversationMirrorService(
        bridge: bridge,
        store: store,
        database: database,
      );
      await service.initialize();
      final published = bridge.messagesForSession('runtime-1').first;

      final handled = await bridge.tryBootstrapSessionHistory(
        runtimeSessionId: 'runtime-1',
        provider: 'codex',
        projectPath: '/tmp/project',
      );

      expect(handled, isTrue);
      expect(service.currentBridgeInstanceId, isNull);
      expect(service.hasLocalCopy(_recentSession), isTrue);
      final history = await published as HistoryMessage;
      expect(
        history.messages.whereType<UserInputMessage>().single.text,
        'available offline',
      );
    },
  );

  test('bootstrap refuses ambiguous copies from two Bridges', () async {
    final messageA = <String, dynamic>{
      'type': 'user_input',
      'text': 'bridge a',
      'userMessageUuid': 'codex:user-turn:0',
    };
    final messageB = <String, dynamic>{
      'type': 'user_input',
      'text': 'bridge b',
      'userMessageUuid': 'codex:user-turn:0',
    };
    await _seedLocalCopy(
      store,
      key: const ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'provider-session-1',
      ),
      message: messageA,
      revision: _hashText('bridge-a-revision'),
      projectPath: '/tmp/project',
    );
    await _seedLocalCopy(
      store,
      key: const ConversationMirrorKey(
        bridgeInstanceId: 'bridge-b',
        provider: 'codex',
        providerSessionId: 'provider-session-1',
      ),
      message: messageB,
      revision: _hashText('bridge-b-revision'),
      projectPath: '/tmp/other-project',
    );
    final databasePath = await database.resolvedPath;
    await service.close();
    bridge.dispose();

    database = ConversationMirrorDatabase(
      databasePath: databasePath,
      openDatabase: openFfi,
    );
    store = _GateableMirrorStore(database);
    bridge = _MirrorTestBridge()
      ..bridgeId = null
      ..connected = false;
    service = ConversationMirrorService(
      bridge: bridge,
      store: store,
      database: database,
    );
    await service.initialize();

    final handled = await bridge.tryBootstrapSessionHistory(
      runtimeSessionId: 'runtime-1',
      provider: 'codex',
      projectPath: '/tmp/project',
    );

    expect(handled, isFalse);
    expect(service.hasLocalCopy(_recentSession), isFalse);
  });

  test(
    'first event migrates a pending watch from Bridge A to Bridge B',
    () async {
      final firstMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'from bridge b',
        'userMessageUuid': 'codex:user-turn:0',
      };
      final download = service.downloadAndWatch(_recentSession);
      await _waitUntil(() async => bridge.sent.isNotEmpty);
      final requestId = bridge.sent.single['requestId'] as String;
      final firstRevision = _hashText('bridge-b-first');
      _emitSnapshot(
        bridge,
        requestId: requestId,
        revision: firstRevision,
        bridgeInstanceId: 'bridge-b',
        messages: [firstMessage],
      );
      expect((await download).success, isTrue);
      expect(service.currentBridgeInstanceId, 'bridge-b');

      final secondMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'later patch from bridge b',
        'userMessageUuid': 'codex:user-turn:1',
      };
      final secondRevision = _hashText('bridge-b-second');
      bridge
        ..emit(
          _event(
            requestId: requestId,
            event: 'accepted',
            bridgeInstanceId: 'bridge-b',
          ),
        )
        ..emit(
          _event(
            requestId: requestId,
            event: 'patch',
            bridgeInstanceId: 'bridge-b',
            revision: secondRevision,
            baseRevision: firstRevision,
            upserts: [
              {
                'entryId': 'entry-1',
                'index': 1,
                'contentHash': _hashJson(secondMessage),
                'message': secondMessage,
              },
            ],
            deletes: const [],
          ),
        );
      await _waitUntil(
        () async =>
            (await service.metadataFor(_recentSession))?.revision ==
            secondRevision,
      );

      final entries = await store.readEntries(
        const ConversationMirrorKey(
          bridgeInstanceId: 'bridge-b',
          provider: 'codex',
          providerSessionId: 'provider-session-1',
        ),
      );
      expect(entries.map((entry) => entry.message['text']), [
        'from bridge b',
        'later patch from bridge b',
      ]);
      expect(
        bridge.sent.where(
          (request) => request['type'] == 'conversation_mirror_unwatch',
        ),
        isEmpty,
      );
    },
  );

  test('rejects a correlated response for a different conversation', () async {
    final download = service.downloadAndWatch(_recentSession);
    await _waitUntil(() async => bridge.sent.isNotEmpty);
    final requestId = bridge.sent.single['requestId'] as String;

    bridge.emit(
      _event(
        requestId: requestId,
        event: 'watching',
        providerSessionId: 'different-thread',
        revision: _hashText('wrong-thread'),
      ),
    );

    final result = await download;
    expect(result.success, isFalse);
    expect(result.errorCode, 'response_identity_mismatch');
    expect(bridge.sent.map((request) => request['type']), [
      'conversation_mirror_watch',
      'conversation_mirror_unwatch',
    ]);
  });

  test(
    'stale snapshot conflict resets without losing the original watch',
    () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-test',
        provider: 'codex',
        providerSessionId: 'provider-session-1',
      );
      final initialMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'revision zero',
        'userMessageUuid': 'codex:user-turn:0',
      };
      final initialRevision = _hashText('conflict-r0');
      await _seedLocalCopy(
        store,
        message: initialMessage,
        revision: initialRevision,
      );
      await service.metadataFor(_recentSession);

      final download = service.downloadAndWatch(_recentSession);
      await _waitUntil(() async => bridge.sent.isNotEmpty);
      final watchRequestId = bridge.sent.single['requestId'] as String;
      final staleMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'stale snapshot',
        'userMessageUuid': 'codex:user-turn:0',
      };
      final staleRevision = _hashText('conflict-r1');
      final staleGeneration = '$watchRequestId:$staleRevision';
      bridge
        ..emit(_event(requestId: watchRequestId, event: 'accepted'))
        ..emit(
          _event(
            requestId: watchRequestId,
            event: 'watching',
            revision: staleRevision,
            threadStatus: 'idle',
          ),
        )
        ..emit(
          _event(
            requestId: watchRequestId,
            event: 'snapshot_begin',
            revision: staleRevision,
            entryCount: 1,
            pageCount: 1,
            totalBytes: utf8.encode(jsonEncode(staleMessage)).length,
          ),
        )
        ..emit(
          _event(
            requestId: watchRequestId,
            event: 'snapshot_page',
            revision: staleRevision,
            pageIndex: 0,
            pageCount: 1,
            entries: [
              {
                'entryId': 'entry-0',
                'index': 0,
                'contentHash': _hashJson(staleMessage),
                'message': staleMessage,
              },
            ],
          ),
        );
      final db = await database.database;
      await _waitUntil(() async {
        final rows = await db.query(
          ConversationMirrorDatabase.stagingTable,
          columns: ['actual_entry_count'],
          where:
              'bridge_instance_id = ? AND provider = ? AND '
              'provider_session_id = ? AND generation = ?',
          whereArgs: [
            key.bridgeInstanceId,
            key.provider,
            key.providerSessionId,
            staleGeneration,
          ],
        );
        return rows.isNotEmpty && rows.single['actual_entry_count'] == 1;
      });

      final desktopMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'desktop wins during snapshot',
        'userMessageUuid': 'codex:user-turn:1',
      };
      final desktopRevision = _hashText('conflict-r2');
      final desktopPatch = await store.applyPatch(
        key: key,
        baseRevision: initialRevision,
        revision: desktopRevision,
        upserts: [
          ConversationMirrorEntryInput(
            entryId: 'entry-1',
            ordinal: 1,
            contentHash: _hashJson(desktopMessage),
            message: desktopMessage,
          ),
        ],
        deletes: const [],
      );
      expect(desktopPatch.applied, isTrue);

      bridge.emit(
        _event(
          requestId: watchRequestId,
          event: 'snapshot_complete',
          revision: staleRevision,
          entryCount: 1,
        ),
      );
      expect((await download).success, isTrue);
      await _waitUntil(
        () async => bridge.sent
            .where((request) => request['type'] == 'conversation_mirror_sync')
            .isNotEmpty,
      );
      final resetRequestId =
          bridge.sent
                  .where(
                    (request) => request['type'] == 'conversation_mirror_sync',
                  )
                  .single['requestId']
              as String;

      final resetRevision = _hashText('conflict-r3');
      final resetMessages = [initialMessage, desktopMessage];
      final resetEntries = <Map<String, dynamic>>[];
      var resetBytes = 0;
      for (var index = 0; index < resetMessages.length; index++) {
        final message = resetMessages[index];
        resetBytes += utf8.encode(jsonEncode(message)).length;
        resetEntries.add({
          'entryId': 'entry-$index',
          'index': index,
          'contentHash': _hashJson(message),
          'message': message,
        });
      }
      bridge
        ..emit(_event(requestId: resetRequestId, event: 'accepted'))
        ..emit(
          _event(
            requestId: resetRequestId,
            event: 'snapshot_begin',
            revision: resetRevision,
            entryCount: resetMessages.length,
            pageCount: 1,
            totalBytes: resetBytes,
          ),
        )
        ..emit(
          _event(
            requestId: resetRequestId,
            event: 'snapshot_page',
            revision: resetRevision,
            pageIndex: 0,
            pageCount: 1,
            entries: resetEntries,
          ),
        )
        ..emit(
          _event(
            requestId: resetRequestId,
            event: 'snapshot_complete',
            revision: resetRevision,
            entryCount: resetMessages.length,
          ),
        );
      await _waitUntil(
        () async =>
            (await service.metadataFor(_recentSession))?.revision ==
            resetRevision,
      );

      final laterMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'watch still alive',
        'userMessageUuid': 'codex:user-turn:2',
      };
      final laterRevision = _hashText('conflict-r4');
      bridge
        ..emit(_event(requestId: watchRequestId, event: 'accepted'))
        ..emit(
          _event(
            requestId: watchRequestId,
            event: 'patch',
            baseRevision: resetRevision,
            revision: laterRevision,
            upserts: [
              {
                'entryId': 'entry-2',
                'index': 2,
                'contentHash': _hashJson(laterMessage),
                'message': laterMessage,
              },
            ],
            deletes: const [],
          ),
        );
      await _waitUntil(
        () async =>
            (await service.metadataFor(_recentSession))?.revision ==
            laterRevision,
      );

      expect(
        (await store.readEntries(key)).map((entry) => entry.message['text']),
        ['revision zero', 'desktop wins during snapshot', 'watch still alive'],
      );
      expect(
        bridge.sent.where(
          (request) => request['type'] == 'conversation_mirror_unwatch',
        ),
        isEmpty,
      );
    },
  );

  test(
    'downloads once, reconciles by revision, and applies Desktop patch',
    () async {
      final published = <ServerMessage>[];
      final publishedSub = bridge
          .messagesForSession('runtime-1')
          .listen(published.add);
      addTearDown(publishedSub.cancel);
      final firstMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'from iPhone',
        'clientMessageId': 'ios-client-1',
        'userMessageUuid': 'codex:user-turn:0',
      };
      final firstHash = _hashJson(firstMessage);
      final firstRevision = _hashText('revision-one');
      String? watchRequestId;

      bridge.onSend = (request) {
        final requestId = request['requestId'] as String;
        if (request['type'] == 'conversation_mirror_watch') {
          watchRequestId = requestId;
          scheduleMicrotask(() {
            bridge
              ..emit(_event(requestId: requestId, event: 'accepted'))
              ..emit(
                _event(
                  requestId: requestId,
                  event: 'watching',
                  revision: firstRevision,
                  threadStatus: 'idle',
                ),
              )
              ..emit(
                _event(
                  requestId: requestId,
                  event: 'snapshot_begin',
                  revision: firstRevision,
                  entryCount: 1,
                  pageCount: 1,
                  totalBytes: utf8.encode(jsonEncode(firstMessage)).length,
                  threadStatus: 'idle',
                ),
              )
              ..emit(
                _event(
                  requestId: requestId,
                  event: 'snapshot_page',
                  revision: firstRevision,
                  pageIndex: 0,
                  pageCount: 1,
                  entries: [
                    {
                      'entryId': 'user-0',
                      'index': 0,
                      'contentHash': firstHash,
                      'message': firstMessage,
                    },
                  ],
                ),
              )
              ..emit(
                _event(
                  requestId: requestId,
                  event: 'snapshot_complete',
                  revision: firstRevision,
                  entryCount: 1,
                  threadStatus: 'idle',
                ),
              );
          });
          return;
        }
        if (request['type'] == 'conversation_mirror_sync') {
          expect(request['knownRevision'], firstRevision);
          scheduleMicrotask(() {
            bridge
              ..emit(_event(requestId: requestId, event: 'accepted'))
              ..emit(
                _event(
                  requestId: requestId,
                  event: 'not_modified',
                  revision: firstRevision,
                  threadStatus: 'idle',
                ),
              );
          });
        }
      };

      final downloaded = await service.downloadAndWatch(_recentSession);
      expect(downloaded.success, isTrue);
      expect(downloaded.changed, isTrue);
      expect(service.hasLocalCopy(_recentSession), isTrue);
      expect((await service.metadataFor(_recentSession))?.autoSync, isTrue);

      final reconciled = await service.syncNow(_recentSession);
      expect(reconciled.success, isTrue);
      expect(reconciled.changed, isFalse);

      final desktopMessage = <String, dynamic>{
        'type': 'user_input',
        'text': 'from Codex Desktop',
        'clientMessageId': 'desktop-client-2',
        'userMessageUuid': 'codex:user-turn:1',
      };
      final secondRevision = _hashText('revision-two');
      final establishedWatchRequestId = watchRequestId!;
      bridge
        ..emit(_event(requestId: establishedWatchRequestId, event: 'accepted'))
        ..emit(
          _event(
            requestId: establishedWatchRequestId,
            event: 'patch',
            revision: secondRevision,
            baseRevision: firstRevision,
            threadStatus: 'idle',
            upserts: [
              {
                'entryId': 'user-1',
                'index': 1,
                'contentHash': _hashJson(desktopMessage),
                'message': desktopMessage,
              },
            ],
            deletes: const [],
          ),
        );
      await _waitUntil(
        () async =>
            (await service.metadataFor(_recentSession))?.revision ==
            secondRevision,
      );

      final entries = await store.readEntries(
        const ConversationMirrorKey(
          bridgeInstanceId: 'bridge-test',
          provider: 'codex',
          providerSessionId: 'provider-session-1',
        ),
      );
      expect(entries, hasLength(2));
      expect(entries.last.message['text'], 'from Codex Desktop');
      expect(entries.last.message['clientMessageId'], 'desktop-client-2');
      final latestHistory = published.whereType<HistoryMessage>().last;
      expect(
        latestHistory.messages.whereType<UserInputMessage>().last.text,
        'from Codex Desktop',
      );
      expect(published.whereType<StatusMessage>(), isEmpty);
    },
  );
}

const _recentSession = RecentSession(
  sessionId: 'provider-session-1',
  provider: 'codex',
  firstPrompt: 'hello',
  created: '2026-07-18T00:00:00Z',
  modified: '2026-07-18T00:00:00Z',
  gitBranch: 'main',
  projectPath: '/tmp/project',
  isSidechain: false,
);

RecentSession _recentSessionWithId(String id, {String? name}) => RecentSession(
  sessionId: id,
  provider: 'codex',
  name: name,
  firstPrompt: id,
  created: '2026-07-18T00:00:00Z',
  modified: '2026-07-18T00:00:00Z',
  gitBranch: 'main',
  projectPath: '/tmp/project',
  isSidechain: false,
);

ConversationMirrorEventMessage _event({
  required String requestId,
  required String event,
  String bridgeInstanceId = 'bridge-test',
  String providerSessionId = 'provider-session-1',
  String? revision,
  String? baseRevision,
  int? entryCount,
  int? totalBytes,
  int? pageIndex,
  int? pageCount,
  String? threadStatus,
  List<Map<String, dynamic>>? entries,
  List<Map<String, dynamic>>? upserts,
  List<String>? deletes,
}) => ConversationMirrorEventMessage.fromJson({
  'type': 'conversation_mirror_event_v1',
  'event': event,
  'requestId': requestId,
  'bridgeInstanceId': bridgeInstanceId,
  'provider': 'codex',
  'providerSessionId': providerSessionId,
  'revision': ?revision,
  'baseRevision': ?baseRevision,
  'entryCount': ?entryCount,
  'totalBytes': ?totalBytes,
  'pageIndex': ?pageIndex,
  'pageCount': ?pageCount,
  'threadStatus': ?threadStatus,
  'entries': ?entries,
  'upserts': ?upserts,
  'deletes': ?deletes,
});

String _hashJson(Map<String, dynamic> value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

String _hashText(String value) => sha256.convert(utf8.encode(value)).toString();

Future<void> _seedLocalCopy(
  ConversationMirrorStore store, {
  ConversationMirrorKey key = const ConversationMirrorKey(
    bridgeInstanceId: 'bridge-test',
    provider: 'codex',
    providerSessionId: 'provider-session-1',
  ),
  required Map<String, dynamic> message,
  required String revision,
  String projectPath = '/tmp/project',
}) async {
  await store.beginShadowGeneration(
    key: key,
    generation: 'cached-generation',
    revision: revision,
    entryCount: 1,
    pageCount: 1,
    totalBytes: utf8.encode(jsonEncode(message)).length,
    autoSync: true,
    projectPath: projectPath,
  );
  await store.appendShadowPage(
    key: key,
    generation: 'cached-generation',
    pageIndex: 0,
    pageCount: 1,
    entries: [
      ConversationMirrorEntryInput(
        entryId: 'cached-user',
        ordinal: 0,
        contentHash: _hashJson(message),
        message: message,
      ),
    ],
  );
  await store.completeShadowGeneration(
    key: key,
    generation: 'cached-generation',
    revision: revision,
    entryCount: 1,
  );
}

Future<void> _seedLocalConversation(
  ConversationMirrorStore store, {
  required int entryCount,
  required String revision,
  Map<String, dynamic> Function(int index)? messageBuilder,
}) async {
  const key = ConversationMirrorKey(
    bridgeInstanceId: 'bridge-test',
    provider: 'codex',
    providerSessionId: 'provider-session-1',
  );
  final messages = List<Map<String, dynamic>>.generate(
    entryCount,
    (index) =>
        messageBuilder?.call(index) ??
        {
          'type': 'user_input',
          'text': 'message-$index',
          'userMessageUuid': 'codex:user-turn:$index',
        },
    growable: false,
  );
  final totalBytes = messages.fold<int>(
    0,
    (total, message) => total + utf8.encode(jsonEncode(message)).length,
  );
  final generation = 'cached-generation-${revision.substring(0, 12)}';
  final pageSize = store.limits.maxEntriesPerPage;
  final pageCount = (entryCount / pageSize).ceil();
  await store.beginShadowGeneration(
    key: key,
    generation: generation,
    revision: revision,
    entryCount: entryCount,
    pageCount: pageCount,
    totalBytes: totalBytes,
    autoSync: true,
    projectPath: '/tmp/project',
  );
  for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
    final start = pageIndex * pageSize;
    final end = (start + pageSize).clamp(0, entryCount);
    await store.appendShadowPage(
      key: key,
      generation: generation,
      pageIndex: pageIndex,
      pageCount: pageCount,
      entries: [
        for (var index = start; index < end; index++)
          ConversationMirrorEntryInput(
            entryId: 'entry-$index',
            ordinal: index,
            contentHash: _hashJson(messages[index]),
            message: messages[index],
          ),
      ],
    );
  }
  await store.completeShadowGeneration(
    key: key,
    generation: generation,
    revision: revision,
    entryCount: entryCount,
  );
}

void _emitSnapshot(
  _MirrorTestBridge bridge, {
  required String requestId,
  required String revision,
  required List<Map<String, dynamic>> messages,
  String bridgeInstanceId = 'bridge-test',
}) {
  final entries = <Map<String, dynamic>>[];
  var totalBytes = 0;
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    totalBytes += utf8.encode(jsonEncode(message)).length;
    entries.add({
      'entryId': 'entry-$index',
      'index': index,
      'contentHash': _hashJson(message),
      'message': message,
    });
  }
  bridge
    ..emit(
      _event(
        requestId: requestId,
        event: 'accepted',
        bridgeInstanceId: bridgeInstanceId,
      ),
    )
    ..emit(
      _event(
        requestId: requestId,
        event: 'watching',
        bridgeInstanceId: bridgeInstanceId,
        revision: revision,
        threadStatus: 'idle',
      ),
    )
    ..emit(
      _event(
        requestId: requestId,
        event: 'snapshot_begin',
        bridgeInstanceId: bridgeInstanceId,
        revision: revision,
        entryCount: messages.length,
        pageCount: 1,
        totalBytes: totalBytes,
        threadStatus: 'idle',
      ),
    )
    ..emit(
      _event(
        requestId: requestId,
        event: 'snapshot_page',
        bridgeInstanceId: bridgeInstanceId,
        revision: revision,
        pageIndex: 0,
        pageCount: 1,
        entries: entries,
      ),
    )
    ..emit(
      _event(
        requestId: requestId,
        event: 'snapshot_complete',
        bridgeInstanceId: bridgeInstanceId,
        revision: revision,
        entryCount: messages.length,
        threadStatus: 'idle',
      ),
    );
}

Future<void> _waitUntil(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for asynchronous mirror state.');
}

class _TestMirrorCancellation implements ConversationMirrorCancellation {
  final Set<void Function()> _listeners = {};
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.from(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}
