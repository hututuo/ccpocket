import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';

const codexSessionLifecycleCapability = 'codex_session_lifecycle_v1';

String archivedSessionIdentityKey(ArchivedSessionRecord session) {
  final sourceId = session.codexSourceId;
  if (session.provider == Provider.codex.value &&
      sourceId != null &&
      sourceId.isNotEmpty) {
    return '${session.provider}\u0000$sourceId\u0000${session.sessionId}';
  }
  return providerSessionIdentityKey(session.provider, session.sessionId);
}

enum _SessionArchiveRequestKind { list, unarchive, delete }

class SessionArchiveState {
  const SessionArchiveState({
    required this.supported,
    this.sessions = const [],
    this.isLoading = false,
    this.pendingSessionKeys = const {},
    this.truncated = false,
    this.error,
  });

  final bool supported;
  final List<ArchivedSessionRecord> sessions;
  final bool isLoading;
  final Set<String> pendingSessionKeys;
  final bool truncated;
  final String? error;

  SessionArchiveState copyWith({
    List<ArchivedSessionRecord>? sessions,
    bool? isLoading,
    Set<String>? pendingSessionKeys,
    bool? truncated,
    String? error,
    bool clearError = false,
  }) => SessionArchiveState(
    supported: supported,
    sessions: sessions ?? this.sessions,
    isLoading: isLoading ?? this.isLoading,
    pendingSessionKeys: pendingSessionKeys ?? this.pendingSessionKeys,
    truncated: truncated ?? this.truncated,
    error: clearError ? null : (error ?? this.error),
  );
}

class _PendingSessionArchiveRequest {
  _PendingSessionArchiveRequest({
    required this.kind,
    required this.completer,
    required this.timer,
    this.sessionId,
    this.provider,
    this.identityKey,
  });

  final _SessionArchiveRequestKind kind;
  final String? sessionId;
  final String? provider;
  final String? identityKey;
  final Completer<bool> completer;
  final Timer timer;
}

class SessionArchiveCubit extends Cubit<SessionArchiveState> {
  SessionArchiveCubit({
    required BridgeService bridge,
    this._requestTimeout = const Duration(seconds: 20),
    String Function()? createRequestId,
  }) : _bridge = bridge,
       _createRequestId = createRequestId ?? const Uuid().v4,
       super(
         SessionArchiveState(
           supported: bridge.bridgeCapabilities.contains(
             codexSessionLifecycleCapability,
           ),
         ),
       ) {
    _messageSubscription = _bridge.messages.listen(_handleMessage);
    _connectionSubscription = _bridge.connectionStatus.listen((status) {
      if (status != BridgeConnectionState.connected) {
        _failAll('Bridge disconnected before confirming the operation.');
      }
    });
    if (state.supported) unawaited(refresh());
  }

  final BridgeService _bridge;
  final Duration _requestTimeout;
  final String Function() _createRequestId;
  final Map<String, _PendingSessionArchiveRequest> _pending = {};
  late final StreamSubscription<ServerMessage> _messageSubscription;
  late final StreamSubscription<BridgeConnectionState> _connectionSubscription;

  Future<bool> refresh() async {
    if (!state.supported || state.isLoading) return false;
    emit(state.copyWith(isLoading: true, clearError: true));
    final requestId = _createRequestId();
    final future = _register(requestId, _SessionArchiveRequestKind.list);
    if (future == null) {
      emit(
        state.copyWith(
          isLoading: false,
          error: 'Duplicate lifecycle request id; request was not sent.',
        ),
      );
      return false;
    }
    try {
      _bridge.send(ClientMessage.listArchivedSessions(requestId: requestId));
    } catch (error) {
      _failRequest(requestId, '$error');
    }
    return future;
  }

  Future<bool> unarchive(ArchivedSessionRecord session) {
    return _mutate(
      session,
      _SessionArchiveRequestKind.unarchive,
      (requestId) => ClientMessage.unarchiveSession(
        requestId: requestId,
        sessionId: session.sessionId,
        provider: session.provider,
        projectPath: session.projectPath,
        codexSourceId: session.codexSourceId,
      ),
    );
  }

  Future<bool> deletePermanently(ArchivedSessionRecord session) {
    if (session.provider != Provider.codex.value) return Future.value(false);
    return _mutate(
      session,
      _SessionArchiveRequestKind.delete,
      (requestId) => ClientMessage.deleteSession(
        requestId: requestId,
        sessionId: session.sessionId,
        projectPath: session.projectPath,
        codexSourceId: session.codexSourceId,
      ),
    );
  }

  Future<bool> _mutate(
    ArchivedSessionRecord session,
    _SessionArchiveRequestKind kind,
    ClientMessage Function(String requestId) buildMessage,
  ) {
    final identityKey = archivedSessionIdentityKey(session);
    if (!state.supported || state.pendingSessionKeys.contains(identityKey)) {
      return Future.value(false);
    }
    final requestId = _createRequestId();
    final future = _register(
      requestId,
      kind,
      sessionId: session.sessionId,
      provider: session.provider,
      identityKey: identityKey,
    );
    if (future == null) {
      emit(
        state.copyWith(
          error: 'Duplicate lifecycle request id; request was not sent.',
        ),
      );
      return Future.value(false);
    }
    emit(
      state.copyWith(
        pendingSessionKeys: {...state.pendingSessionKeys, identityKey},
        clearError: true,
      ),
    );
    try {
      _bridge.send(buildMessage(requestId));
    } catch (error) {
      _failRequest(requestId, '$error');
    }
    return future;
  }

  Future<bool>? _register(
    String requestId,
    _SessionArchiveRequestKind kind, {
    String? sessionId,
    String? provider,
    String? identityKey,
  }) {
    if (_pending.containsKey(requestId)) return null;
    final completer = Completer<bool>();
    late final Timer timer;
    timer = Timer(_requestTimeout, () {
      _failRequest(
        requestId,
        'The Bridge did not confirm the operation in time.',
      );
    });
    _pending[requestId] = _PendingSessionArchiveRequest(
      kind: kind,
      sessionId: sessionId,
      provider: provider,
      identityKey: identityKey,
      completer: completer,
      timer: timer,
    );
    return completer.future;
  }

  void _handleMessage(ServerMessage message) {
    switch (message) {
      case ArchivedSessionsResultMessage():
        final pending = _pending[message.requestId];
        if (pending?.kind != _SessionArchiveRequestKind.list) return;
        _finishRequest(message.requestId, message.success);
        if (message.success) {
          emit(
            state.copyWith(
              sessions: message.sessions,
              isLoading: false,
              truncated: message.truncated,
              clearError: true,
            ),
          );
        } else {
          emit(
            state.copyWith(
              isLoading: false,
              error: message.error ?? message.errorCode ?? 'Unknown error',
            ),
          );
        }
      case SessionLifecycleResultMessage():
        final pending = _pending[message.requestId];
        if (pending == null || pending.sessionId != message.sessionId) return;
        final expectedType = switch (pending.kind) {
          _SessionArchiveRequestKind.unarchive => 'unarchive_result',
          _SessionArchiveRequestKind.delete => 'delete_session_result',
          _SessionArchiveRequestKind.list => '',
        };
        if (message.type != expectedType) return;
        _finishRequest(message.requestId, message.success);
        final pendingKeys = {...state.pendingSessionKeys};
        if (pending.identityKey != null) {
          pendingKeys.remove(pending.identityKey);
        }
        if (message.success) {
          emit(
            state.copyWith(
              sessions: state.sessions
                  .where(
                    (session) =>
                        session.sessionId != message.sessionId ||
                        session.provider != pending.provider,
                  )
                  .toList(),
              pendingSessionKeys: pendingKeys,
              clearError: true,
            ),
          );
        } else {
          emit(
            state.copyWith(
              pendingSessionKeys: pendingKeys,
              error: message.error ?? message.errorCode ?? 'Unknown error',
            ),
          );
        }
      default:
        return;
    }
  }

  void _finishRequest(String requestId, bool success) {
    final pending = _pending.remove(requestId);
    if (pending == null) return;
    pending.timer.cancel();
    if (!pending.completer.isCompleted) pending.completer.complete(success);
  }

  void _failRequest(String requestId, String error) {
    final pending = _pending.remove(requestId);
    if (pending == null) return;
    pending.timer.cancel();
    if (!pending.completer.isCompleted) pending.completer.complete(false);
    final pendingKeys = {...state.pendingSessionKeys};
    if (pending.identityKey != null) pendingKeys.remove(pending.identityKey);
    if (!isClosed) {
      emit(
        state.copyWith(
          isLoading: pending.kind == _SessionArchiveRequestKind.list
              ? false
              : state.isLoading,
          pendingSessionKeys: pendingKeys,
          error: error,
        ),
      );
    }
  }

  void _failAll(String error) {
    for (final requestId in _pending.keys.toList()) {
      _failRequest(requestId, error);
    }
  }

  @override
  Future<void> close() async {
    await _messageSubscription.cancel();
    await _connectionSubscription.cancel();
    _failAll('Archived-session view closed before the operation completed.');
    return super.close();
  }
}
