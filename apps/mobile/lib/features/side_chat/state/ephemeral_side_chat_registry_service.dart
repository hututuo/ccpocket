import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';

abstract interface class EphemeralSideChatBridgeGateway {
  bool get isConnected;
  Set<String> get capabilities;
  Stream<BridgeConnectionState> get connectionStatus;
  Stream<void> get capabilityChanges;
  Stream<LocalFeatureServerMessage> get messages;
  Stream<String> get stoppedSessions;
  void send(ClientMessage message);
}

class BridgeServiceEphemeralSideChatGateway
    implements EphemeralSideChatBridgeGateway {
  const BridgeServiceEphemeralSideChatGateway(this._bridge);

  final BridgeService _bridge;

  @override
  bool get isConnected => _bridge.isConnected;

  @override
  Set<String> get capabilities => _bridge.bridgeCapabilities;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _bridge.connectionStatus;

  @override
  Stream<void> get capabilityChanges => _bridge.sessionList
      .map(
        (_) => (
          connected: _bridge.isConnected,
          supported: _bridge.bridgeCapabilities.contains(
            ephemeralSideChatCapability,
          ),
        ),
      )
      .distinct()
      .map<void>((_) {});

  @override
  Stream<LocalFeatureServerMessage> get messages =>
      _bridge.localFeatureMessages;

  @override
  Stream<String> get stoppedSessions => _bridge.stoppedSessions;

  @override
  void send(ClientMessage message) => _bridge.send(message);
}

class EphemeralSideChatRegistryService extends ChangeNotifier {
  EphemeralSideChatRegistryService({
    required EphemeralSideChatBridgeGateway bridge,
    Duration requestTimeout = const Duration(seconds: 15),
  }) : this._(bridge, requestTimeout);

  EphemeralSideChatRegistryService._(this._bridge, this._requestTimeout) {
    _messageSubscription = _bridge.messages.listen(_onMessage);
    _connectionSubscription = _bridge.connectionStatus.listen(
      _onConnectionState,
    );
    _capabilitySubscription = _bridge.capabilityChanges.listen(
      (_) => _reconcileCapability(),
    );
    _stoppedSessionSubscription = _bridge.stoppedSessions.listen(
      _removeStoppedSession,
    );
    if (_bridge.isConnected) {
      scheduleMicrotask(_reconcileCapability);
    }
  }

  final EphemeralSideChatBridgeGateway _bridge;
  final Duration _requestTimeout;
  final Map<String, EphemeralSideChatEntry> _entriesById = {};
  final Map<String, _PendingOpen> _pendingOpens = {};
  final Map<String, _PendingRegistryRequest> _pendingRegistryRequests = {};
  StreamSubscription<LocalFeatureServerMessage>? _messageSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<void>? _capabilitySubscription;
  StreamSubscription<String>? _stoppedSessionSubscription;
  Future<void>? _refreshFuture;
  bool _disposed = false;

  bool get isSupported =>
      _bridge.capabilities.contains(ephemeralSideChatCapability);

  List<EphemeralSideChatEntry> get entries {
    final values = _entriesById.values.toList()
      ..sort(
        (left, right) => right.lastActivityAt.compareTo(left.lastActivityAt),
      );
    return List.unmodifiable(values);
  }

  List<EphemeralSideChatEntry> entriesForParent(String parentSessionId) =>
      List.unmodifiable(
        entries.where((entry) => entry.parentSessionId == parentSessionId),
      );

  EphemeralSideChatEntry? entryForChild(String childSessionId) =>
      _entriesById[childSessionId];

  Future<EphemeralSideChatEntry> open(String parentSessionId) {
    _requireAvailable();
    final requestId = const Uuid().v4();
    final completer = Completer<EphemeralSideChatEntry>();
    final timer = Timer(_requestTimeout, () {
      final pending = _pendingOpens.remove(requestId);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          TimeoutException(
            'Timed out opening the ephemeral side chat.',
            _requestTimeout,
          ),
        );
      }
    });
    _pendingOpens[requestId] = _PendingOpen(completer: completer, timer: timer);
    try {
      _bridge.send(
        requestOpenEphemeralSideChat(
          parentSessionId: parentSessionId,
          requestId: requestId,
        ),
      );
    } catch (error, stackTrace) {
      _pendingOpens.remove(requestId);
      timer.cancel();
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  Future<void> refresh() {
    if (!_bridge.isConnected || !isSupported) {
      return Future<void>.value();
    }
    final inFlight = _refreshFuture;
    if (inFlight != null) return inFlight;

    final requestId = const Uuid().v4();
    final completer = Completer<void>();
    final timer = Timer(
      _requestTimeout,
      () => _failRegistryRequest(
        requestId,
        TimeoutException(
          'Timed out refreshing ephemeral side chats.',
          _requestTimeout,
        ),
      ),
    );
    _pendingRegistryRequests[requestId] = _PendingRegistryRequest(
      completer: completer,
      timer: timer,
    );
    late final Future<void> future;
    future = completer.future.whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
    _refreshFuture = future;
    try {
      _bridge.send(requestListEphemeralSideChats(requestId: requestId));
    } catch (error, stackTrace) {
      _failRegistryRequest(requestId, error, stackTrace);
    }
    return future;
  }

  Future<void> close(String childSessionId) {
    _requireAvailable();
    final requestId = const Uuid().v4();
    final completer = Completer<void>();
    final timer = Timer(
      _requestTimeout,
      () => _failRegistryRequest(
        requestId,
        TimeoutException(
          'Timed out closing the ephemeral side chat.',
          _requestTimeout,
        ),
      ),
    );
    _pendingRegistryRequests[requestId] = _PendingRegistryRequest(
      completer: completer,
      timer: timer,
    );
    try {
      _bridge.send(
        requestCloseEphemeralSideChat(
          childSessionId: childSessionId,
          requestId: requestId,
        ),
      );
    } catch (error, stackTrace) {
      _failRegistryRequest(requestId, error, stackTrace);
    }
    return completer.future;
  }

  void _requireAvailable() {
    if (!_bridge.isConnected) {
      throw StateError('Bridge is disconnected.');
    }
    if (!isSupported) {
      throw StateError('Bridge does not support ephemeral side chats.');
    }
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (state == BridgeConnectionState.connected) {
      _reconcileCapability();
      return;
    }
    _failPending(StateError('Bridge disconnected during the request.'));
  }

  void _reconcileCapability() {
    if (_disposed || !_bridge.isConnected) return;
    if (!isSupported) {
      if (_entriesById.isNotEmpty) {
        _entriesById.clear();
        notifyListeners();
      }
      return;
    }
    unawaited(refresh().catchError((_) {}));
  }

  void _onMessage(LocalFeatureServerMessage message) {
    if (message is EphemeralSideChatOpenedMessage) {
      final pending = _pendingOpens.remove(message.requestId);
      pending?.timer.cancel();
      final entry = message.entry;
      if (entry != null) {
        _entriesById[entry.childSessionId] = entry;
        notifyListeners();
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(entry);
        }
      } else if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError(message.error ?? 'Unable to open the side chat.'),
        );
      }
      return;
    }

    if (message is EphemeralSideChatRegistryMessage) {
      final entries = message.entries;
      if (entries != null) {
        _replaceEntries(entries);
        final requestId = message.requestId;
        if (requestId != null) _completeRegistryRequest(requestId);
      } else {
        final requestId = message.requestId;
        if (requestId != null) {
          _failRegistryRequest(
            requestId,
            StateError(message.error ?? 'Unable to update side chats.'),
          );
        }
      }
      return;
    }

    if (message case LocalFeatureRequestErrorMessage(
      featureId: 'ephemeral_side_chat',
      :final requestId,
      :final message,
    )) {
      if (requestId == null) return;
      final error = StateError(message);
      final open = _pendingOpens.remove(requestId);
      if (open != null) {
        open.timer.cancel();
        if (!open.completer.isCompleted) open.completer.completeError(error);
      } else {
        _failRegistryRequest(requestId, error);
      }
    }
  }

  void _replaceEntries(Iterable<EphemeralSideChatEntry> entries) {
    _entriesById
      ..clear()
      ..addEntries(
        entries.map((entry) => MapEntry(entry.childSessionId, entry)),
      );
    notifyListeners();
  }

  void _removeStoppedSession(String sessionId) {
    if (_entriesById.remove(sessionId) != null) notifyListeners();
  }

  void _completeRegistryRequest(String requestId) {
    final pending = _pendingRegistryRequests.remove(requestId);
    pending?.timer.cancel();
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete();
    }
  }

  void _failRegistryRequest(
    String requestId,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    final pending = _pendingRegistryRequests.remove(requestId);
    pending?.timer.cancel();
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(error, stackTrace);
    }
  }

  void _failPending(Object error) {
    for (final pending in _pendingOpens.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pendingOpens.clear();
    for (final pending in _pendingRegistryRequests.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pendingRegistryRequests.clear();
    _refreshFuture = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _failPending(StateError('Ephemeral side chat registry was disposed.'));
    unawaited(_messageSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_capabilitySubscription?.cancel());
    unawaited(_stoppedSessionSubscription?.cancel());
    super.dispose();
  }
}

class _PendingOpen {
  const _PendingOpen({required this.completer, required this.timer});

  final Completer<EphemeralSideChatEntry> completer;
  final Timer timer;
}

class _PendingRegistryRequest {
  const _PendingRegistryRequest({required this.completer, required this.timer});

  final Completer<void> completer;
  final Timer timer;
}
