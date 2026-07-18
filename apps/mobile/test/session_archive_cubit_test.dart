import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_archive/session_archive_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _ArchiveBridge extends BridgeService {
  _ArchiveBridge({this.supported = true});

  final bool supported;
  final messagesController = StreamController<ServerMessage>.broadcast();
  final connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final sent = <ClientMessage>[];

  @override
  Set<String> get bridgeCapabilities =>
      supported ? const {codexSessionLifecycleCapability} : const {};

  @override
  Stream<ServerMessage> get messages => messagesController.stream;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      connectionController.stream;

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  void dispose() {
    messagesController.close();
    connectionController.close();
  }
}

const _archived = ArchivedSessionRecord(
  sessionId: 'thread-1',
  provider: 'codex',
  projectPath: '/project',
  archivedAt: '2026-07-18T00:00:00Z',
  name: 'Archived thread',
);

void main() {
  test('loads archived sessions only when capability is advertised', () async {
    final bridge = _ArchiveBridge();
    final ids = ['list-1'].iterator;
    ids.moveNext();
    final cubit = SessionArchiveCubit(
      bridge: bridge,
      createRequestId: () => ids.current,
    );
    addTearDown(() async {
      await cubit.close();
      bridge.dispose();
    });

    expect(bridge.sent, hasLength(1));
    expect(jsonDecode(bridge.sent.single.toJson()), {
      'type': 'list_archived_sessions',
      'requestId': 'list-1',
    });

    bridge.messagesController.add(
      const ArchivedSessionsResultMessage(
        requestId: 'list-1',
        success: true,
        sessions: [_archived],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.sessions, [_archived]);
    expect(cubit.state.isLoading, isFalse);
  });

  test('old Bridge remains untouched and the feature is unsupported', () {
    final bridge = _ArchiveBridge(supported: false);
    final cubit = SessionArchiveCubit(bridge: bridge);
    addTearDown(() async {
      await cubit.close();
      bridge.dispose();
    });

    expect(cubit.state.supported, isFalse);
    expect(bridge.sent, isEmpty);
  });

  test('restore ignores mismatched request and session results', () async {
    final bridge = _ArchiveBridge();
    final ids = ['list-1', 'restore-1'].iterator;
    String nextId() {
      ids.moveNext();
      return ids.current;
    }

    final cubit = SessionArchiveCubit(bridge: bridge, createRequestId: nextId);
    addTearDown(() async {
      await cubit.close();
      bridge.dispose();
    });
    bridge.messagesController.add(
      const ArchivedSessionsResultMessage(
        requestId: 'list-1',
        success: true,
        sessions: [_archived],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final restored = cubit.unarchive(_archived);
    bridge.messagesController.add(
      const SessionLifecycleResultMessage(
        type: 'unarchive_result',
        requestId: 'wrong-request',
        sessionId: 'thread-1',
        success: true,
      ),
    );
    bridge.messagesController.add(
      const SessionLifecycleResultMessage(
        type: 'unarchive_result',
        requestId: 'restore-1',
        sessionId: 'wrong-thread',
        success: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.sessions, [_archived]);

    bridge.messagesController.add(
      const SessionLifecycleResultMessage(
        type: 'unarchive_result',
        requestId: 'restore-1',
        sessionId: 'thread-1',
        success: true,
      ),
    );
    await expectLater(restored, completion(isTrue));
    expect(cubit.state.sessions, isEmpty);
  });

  test(
    'delete sends the strong server confirmation and keeps failures visible',
    () async {
      final bridge = _ArchiveBridge();
      final ids = ['list-1', 'delete-1'].iterator;
      String nextId() {
        ids.moveNext();
        return ids.current;
      }

      final cubit = SessionArchiveCubit(
        bridge: bridge,
        createRequestId: nextId,
      );
      addTearDown(() async {
        await cubit.close();
        bridge.dispose();
      });
      bridge.messagesController.add(
        const ArchivedSessionsResultMessage(
          requestId: 'list-1',
          success: true,
          sessions: [_archived],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final deleted = cubit.deletePermanently(_archived);
      final sent =
          jsonDecode(bridge.sent.last.toJson()) as Map<String, dynamic>;
      expect(sent['type'], 'delete_session');
      expect(sent['confirmDescendantDeletion'], isTrue);
      bridge.messagesController.add(
        const SessionLifecycleResultMessage(
          type: 'delete_session_result',
          requestId: 'delete-1',
          sessionId: 'thread-1',
          success: false,
          errorCode: 'partial_failure',
          error: 'Provider deleted the thread but local cleanup failed',
        ),
      );

      await expectLater(deleted, completion(isFalse));
      expect(cubit.state.sessions, [_archived]);
      expect(cubit.state.error, contains('local cleanup failed'));
    },
  );

  test('disconnect fails an in-flight request without queueing it', () async {
    final bridge = _ArchiveBridge();
    final ids = ['list-1'].iterator;
    ids.moveNext();
    final cubit = SessionArchiveCubit(
      bridge: bridge,
      createRequestId: () => ids.current,
    );
    addTearDown(() async {
      await cubit.close();
      bridge.dispose();
    });

    bridge.connectionController.add(BridgeConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.isLoading, isFalse);
    expect(cubit.state.error, contains('disconnected'));
    expect(bridge.sent.single.delivery, ClientMessageDelivery.ephemeral);
  });

  test(
    'same session id from different providers has independent busy state',
    () async {
      final bridge = _ArchiveBridge();
      final ids = ['list-1', 'restore-codex', 'restore-claude'].iterator;
      String nextId() {
        ids.moveNext();
        return ids.current;
      }

      const claude = ArchivedSessionRecord(
        sessionId: 'thread-1',
        provider: 'claude',
        projectPath: '/claude-project',
        archivedAt: '2026-07-18T00:00:00Z',
      );
      final cubit = SessionArchiveCubit(
        bridge: bridge,
        createRequestId: nextId,
      );
      addTearDown(() async {
        await cubit.close();
        bridge.dispose();
      });
      bridge.messagesController.add(
        const ArchivedSessionsResultMessage(
          requestId: 'list-1',
          success: true,
          sessions: [_archived, claude],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final codexRestore = cubit.unarchive(_archived);
      final claudeRestore = cubit.unarchive(claude);
      expect(cubit.state.pendingSessionKeys, {
        archivedSessionIdentityKey(_archived),
        archivedSessionIdentityKey(claude),
      });

      bridge.messagesController.add(
        const SessionLifecycleResultMessage(
          type: 'unarchive_result',
          requestId: 'restore-codex',
          sessionId: 'thread-1',
          success: true,
        ),
      );
      await expectLater(codexRestore, completion(isTrue));
      expect(cubit.state.sessions, [claude]);
      expect(cubit.state.pendingSessionKeys, {
        archivedSessionIdentityKey(claude),
      });

      bridge.messagesController.add(
        const SessionLifecycleResultMessage(
          type: 'unarchive_result',
          requestId: 'restore-claude',
          sessionId: 'thread-1',
          success: true,
        ),
      );
      await expectLater(claudeRestore, completion(isTrue));
      expect(cubit.state.sessions, isEmpty);
    },
  );

  test(
    'duplicate request ids fail closed without replacing an owner',
    () async {
      final bridge = _ArchiveBridge();
      final cubit = SessionArchiveCubit(
        bridge: bridge,
        createRequestId: () => 'duplicate-id',
      );
      addTearDown(() async {
        await cubit.close();
        bridge.dispose();
      });

      final deleted = await cubit.deletePermanently(_archived);

      expect(deleted, isFalse);
      expect(bridge.sent, hasLength(1));
      expect(cubit.state.error, contains('Duplicate lifecycle request id'));
    },
  );
}
