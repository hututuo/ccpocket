import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import '../session_list/cache/session_catalog_cache_repository.dart';

abstract interface class ConversationContentSyncGateway {
  Stream<BridgeConnectionState> get connectionStatus;
  Stream<List<SessionInfo>> get sessionList;
  Stream<LocalFeatureServerMessage> get localFeatureMessages;
  Stream<ClientDeliveryModeStateMessage> get clientDeliveryModeStates;

  BridgeConnectionState get currentBridgeConnectionState;
  String? get bridgeInstanceId;
  String? get codexSourceId;
  String? get logicalConnectionIdentity;
  String? get lastUrl;
  bool get supportsConversationContentEvents;
  BridgeClientDeliveryMode get desiredClientDeliveryMode;

  void send(ClientMessage message);
}

class BridgeServiceConversationContentSyncGateway
    implements ConversationContentSyncGateway {
  const BridgeServiceConversationContentSyncGateway(this.bridge);

  final BridgeService bridge;

  @override
  Stream<BridgeConnectionState> get connectionStatus => bridge.connectionStatus;

  @override
  Stream<List<SessionInfo>> get sessionList => bridge.sessionList;

  @override
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      bridge.localFeatureMessages;

  @override
  Stream<ClientDeliveryModeStateMessage> get clientDeliveryModeStates =>
      bridge.clientDeliveryModeStates;

  @override
  BridgeConnectionState get currentBridgeConnectionState =>
      bridge.currentBridgeConnectionState;

  @override
  String? get bridgeInstanceId => bridge.bridgeInstanceId;

  @override
  String? get codexSourceId => bridge.codexSourceId;

  @override
  String? get logicalConnectionIdentity => bridge.logicalConnectionIdentity;

  @override
  String? get lastUrl => bridge.lastUrl;

  @override
  bool get supportsConversationContentEvents =>
      bridge.supportsConversationContentEvents;

  @override
  BridgeClientDeliveryMode get desiredClientDeliveryMode =>
      bridge.desiredClientDeliveryMode;

  @override
  void send(ClientMessage message) => bridge.send(message);
}

class ConversationContentCacheUpdate {
  const ConversationContentCacheUpdate({
    required this.provider,
    required this.providerSessionId,
    required this.revision,
  });

  final String provider;
  final String providerSessionId;
  final String revision;
}

/// Maintains one foreground subscription to the Bridge-owned conversation
/// scheduler.
///
/// The phone never polls individual conversations. Snapshot pages are staged
/// in memory and atomically committed before ACK; patches are applied only
/// against the exact durable base revision. Background lifecycle states reject
/// body events and unsubscribe, preserving notification-only behavior.
class ConversationContentSyncService with WidgetsBindingObserver {
  ConversationContentSyncService({
    required this.bridge,
    required this.cache,
    this.retryBaseDelay = const Duration(seconds: 2),
    this.retryMaxDelay = const Duration(seconds: 30),
  });

  final ConversationContentSyncGateway bridge;
  final SessionCatalogCacheRepository cache;
  final Duration retryBaseDelay;
  final Duration retryMaxDelay;

  final StreamController<ConversationContentCacheUpdate> _updatesController =
      StreamController<ConversationContentCacheUpdate>.broadcast();
  final Map<String, _SnapshotStage> _stages = {};

  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<List<SessionInfo>>? _sessionListSubscription;
  StreamSubscription<LocalFeatureServerMessage>? _messageSubscription;
  StreamSubscription<ClientDeliveryModeStateMessage>? _deliveryModeSubscription;
  Timer? _retryTimer;

  ConversationContentTarget? _focused;
  String? _pendingSubscriptionId;
  String? _activeSubscriptionId;
  String? _subscriptionTargetFingerprint;
  bool _foreground = false;
  bool _started = false;
  bool _disposed = false;
  int _generation = 0;
  int _requestSequence = 0;
  int _retryAttempt = 0;

  Stream<ConversationContentCacheUpdate> get updates =>
      _updatesController.stream;

  void start({AppLifecycleState? initialLifecycleState}) {
    if (_started || _disposed) return;
    _started = true;
    _foreground = initialLifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _connectionSubscription = bridge.connectionStatus.listen(
      _handleConnectionState,
    );
    _sessionListSubscription = bridge.sessionList.listen((_) {
      _ensureSubscribed();
    });
    _messageSubscription = bridge.localFeatureMessages.listen((message) {
      if (message is ConversationContentEventMessage) {
        _handleEvent(message);
      }
    });
    _deliveryModeSubscription = bridge.clientDeliveryModeStates.listen(
      _handleDeliveryMode,
    );
    _ensureSubscribed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _ensureSubscribed();
      return;
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _stopSubscription(sendUnsubscribe: true);
    }
  }

  void setFocusedConversation({String? provider, String? providerSessionId}) {
    final next = provider == null || providerSessionId == null
        ? null
        : ConversationContentTarget(
            provider: provider,
            providerSessionId: providerSessionId,
          );
    if (_sameTarget(_focused, next)) return;
    _focused = next;
    final subscriptionId = _activeSubscriptionId;
    if (subscriptionId == null) {
      if (_canProcessContent) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _ensureSubscribed();
      }
      return;
    }
    if (!_canProcessContent) return;
    try {
      bridge.send(
        conversationContentFocus(
          requestId: _nextRequestId('focus'),
          subscriptionId: subscriptionId,
          focused: next,
        ),
      );
    } catch (_) {
      _handleTransportLoss();
    }
  }

  void clearFocusedConversation({
    required String provider,
    required String providerSessionId,
  }) {
    if (_focused?.provider != provider ||
        _focused?.providerSessionId != providerSessionId) {
      return;
    }
    setFocusedConversation();
  }

  Future<ConversationHotWindowSnapshot?> loadCachedWindow({
    required String provider,
    required String providerSessionId,
  }) {
    return cache.loadConversationWindow(
      target: _cacheTarget,
      provider: provider,
      providerSessionId: providerSessionId,
    );
  }

  bool get _canProcessContent =>
      _foreground &&
      bridge.currentBridgeConnectionState == BridgeConnectionState.connected &&
      bridge.desiredClientDeliveryMode ==
          BridgeClientDeliveryMode.interactive &&
      bridge.supportsConversationContentEvents &&
      bridge.bridgeInstanceId?.isNotEmpty == true;

  SessionCatalogCacheTarget get _cacheTarget =>
      SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.bridgeInstanceId,
        codexSourceId: bridge.codexSourceId,
        logicalConnectionIdentity: bridge.logicalConnectionIdentity,
        websocketUrl: bridge.lastUrl,
      );

  void _handleConnectionState(BridgeConnectionState state) {
    if (state == BridgeConnectionState.connected) {
      _ensureSubscribed();
      return;
    }
    _handleTransportLoss();
  }

  void _handleDeliveryMode(ClientDeliveryModeStateMessage state) {
    if (state.mode == BridgeClientDeliveryMode.interactive) {
      _ensureSubscribed();
      return;
    }
    _stages.clear();
  }

  void _handleTransportLoss() {
    _generation += 1;
    _pendingSubscriptionId = null;
    _activeSubscriptionId = null;
    _subscriptionTargetFingerprint = null;
    _stages.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
  }

  void _ensureSubscribed() {
    final target = _cacheTarget;
    final targetFingerprint = target.fingerprint;
    if (_subscriptionTargetFingerprint != null &&
        _subscriptionTargetFingerprint != targetFingerprint) {
      _stopSubscription(sendUnsubscribe: false);
    }
    if (_disposed ||
        !_canProcessContent ||
        _pendingSubscriptionId != null ||
        _activeSubscriptionId != null) {
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    final generation = ++_generation;
    final requestId = _nextRequestId('subscribe');
    _pendingSubscriptionId = requestId;
    _subscriptionTargetFingerprint = targetFingerprint;
    unawaited(
      cache
          .knownConversationRevisions(target)
          .then((knownRevisions) {
            if (_disposed ||
                generation != _generation ||
                _pendingSubscriptionId != requestId ||
                !_canProcessContent ||
                _subscriptionTargetFingerprint != _cacheTarget.fingerprint ||
                target.fingerprint != _cacheTarget.fingerprint) {
              return;
            }
            try {
              bridge.send(
                conversationContentSubscribe(
                  requestId: requestId,
                  knownRevisions: knownRevisions,
                  focused: _focused,
                ),
              );
            } catch (_) {
              if (generation == _generation) {
                _pendingSubscriptionId = null;
                _scheduleRetry();
              }
            }
          })
          .catchError((Object _) {
            if (generation == _generation) {
              _pendingSubscriptionId = null;
              _scheduleRetry();
            }
          }),
    );
  }

  void _handleEvent(ConversationContentEventMessage event) {
    if (!_canProcessContent ||
        event.bridgeInstanceId != bridge.bridgeInstanceId ||
        _subscriptionTargetFingerprint != _cacheTarget.fingerprint ||
        (event.subscriptionId != _activeSubscriptionId &&
            event.subscriptionId != _pendingSubscriptionId)) {
      return;
    }
    switch (event.event) {
      case ConversationContentEventKind.subscribed:
        if (event.requestId != _pendingSubscriptionId) return;
        _activeSubscriptionId = event.subscriptionId;
        _pendingSubscriptionId = null;
      case ConversationContentEventKind.focusApplied:
      case ConversationContentEventKind.unsubscribed:
        return;
      case ConversationContentEventKind.snapshotBegin:
        _beginSnapshot(event);
      case ConversationContentEventKind.snapshotPage:
        _stageSnapshotPage(event);
      case ConversationContentEventKind.snapshotComplete:
        unawaited(_completeSnapshot(event));
      case ConversationContentEventKind.patch:
        unawaited(_applyPatch(event));
      case ConversationContentEventKind.error:
        _handleError(event);
    }
  }

  void _beginSnapshot(ConversationContentEventMessage event) {
    final key = _stageKey(event);
    _stages[key] = _SnapshotStage(
      provider: event.provider!,
      providerSessionId: event.providerSessionId!,
      revision: event.revision!,
      entryCount: event.entryCount!,
      pageCount: event.pageCount!,
      hasEarlier: event.hasEarlier!,
      sourceEntryCount: event.sourceEntryCount!,
    );
  }

  void _stageSnapshotPage(ConversationContentEventMessage event) {
    final stage = _stages[_stageKey(event)];
    if (stage == null ||
        stage.pageCount != event.pageCount ||
        stage.pages.containsKey(event.pageIndex)) {
      return;
    }
    stage.pages[event.pageIndex!] = event.entries;
  }

  Future<void> _completeSnapshot(ConversationContentEventMessage event) async {
    final generation = _generation;
    final subscriptionId = _activeSubscriptionId;
    final target = _cacheTarget;
    final key = _stageKey(event);
    final stage = _stages.remove(key);
    if (stage == null ||
        stage.entryCount != event.entryCount ||
        stage.hasEarlier != event.hasEarlier ||
        stage.sourceEntryCount != event.sourceEntryCount ||
        stage.pages.length != stage.pageCount) {
      _restartSubscription();
      return;
    }
    final entries = <ConversationContentWireEntry>[];
    for (var page = 0; page < stage.pageCount; page++) {
      final pageEntries = stage.pages[page];
      if (pageEntries == null) {
        _restartSubscription();
        return;
      }
      entries.addAll(pageEntries);
    }
    if (entries.length != stage.entryCount ||
        entries.map((entry) => entry.entryId).toSet().length !=
            entries.length ||
        entries.map((entry) => entry.index).toSet().length != entries.length) {
      _restartSubscription();
      return;
    }
    entries.sort((left, right) => left.index.compareTo(right.index));
    try {
      await cache.replaceConversationWindow(
        target: target,
        provider: stage.provider,
        providerSessionId: stage.providerSessionId,
        revision: stage.revision,
        entries: entries,
        hasEarlier: stage.hasEarlier,
        sourceEntryCount: stage.sourceEntryCount,
      );
    } catch (error) {
      debugPrint('Conversation content snapshot cache failed: $error');
      if (_isCurrent(generation, subscriptionId, target)) {
        _restartSubscription();
      }
      return;
    }
    if (!_isCurrent(generation, subscriptionId, target)) return;
    _publishCommit(
      provider: stage.provider,
      providerSessionId: stage.providerSessionId,
      revision: stage.revision,
    );
  }

  Future<void> _applyPatch(ConversationContentEventMessage event) async {
    final generation = _generation;
    final subscriptionId = _activeSubscriptionId;
    final target = _cacheTarget;
    final provider = event.provider!;
    final providerSessionId = event.providerSessionId!;
    bool applied;
    try {
      applied = await cache.applyConversationPatch(
        target: target,
        provider: provider,
        providerSessionId: providerSessionId,
        baseRevision: event.baseRevision!,
        revision: event.revision!,
        upserts: event.entries,
        deletes: event.deletes,
        hasEarlier: event.hasEarlier!,
        sourceEntryCount: event.sourceEntryCount!,
      );
    } catch (error) {
      debugPrint('Conversation content patch cache failed: $error');
      applied = false;
    }
    if (!_isCurrent(generation, subscriptionId, target)) return;
    if (!applied) {
      await cache.deleteConversationWindow(
        target: target,
        provider: provider,
        providerSessionId: providerSessionId,
      );
      if (_isCurrent(generation, subscriptionId, target)) {
        _stopSubscription(sendUnsubscribe: true);
        _ensureSubscribed();
      }
      return;
    }
    _publishCommit(
      provider: provider,
      providerSessionId: providerSessionId,
      revision: event.revision!,
    );
  }

  void _publishCommit({
    required String provider,
    required String providerSessionId,
    required String revision,
  }) {
    final subscriptionId = _activeSubscriptionId;
    if (subscriptionId == null || !_canProcessContent) return;
    try {
      bridge.send(
        conversationContentAck(
          subscriptionId: subscriptionId,
          cursor: ConversationContentCursor(
            provider: provider,
            providerSessionId: providerSessionId,
            revision: revision,
          ),
        ),
      );
    } catch (_) {
      _handleTransportLoss();
      return;
    }
    _updatesController.add(
      ConversationContentCacheUpdate(
        provider: provider,
        providerSessionId: providerSessionId,
        revision: revision,
      ),
    );
    _retryAttempt = 0;
  }

  void _handleError(ConversationContentEventMessage event) {
    if (event.requestId == _pendingSubscriptionId) {
      _pendingSubscriptionId = null;
      _scheduleRetry();
    }
  }

  bool _isCurrent(
    int generation,
    String? subscriptionId,
    SessionCatalogCacheTarget target,
  ) {
    return !_disposed &&
        generation == _generation &&
        subscriptionId != null &&
        subscriptionId == _activeSubscriptionId &&
        target.fingerprint == _cacheTarget.fingerprint &&
        _canProcessContent;
  }

  void _stopSubscription({required bool sendUnsubscribe}) {
    final subscriptionId = _activeSubscriptionId ?? _pendingSubscriptionId;
    _generation += 1;
    _activeSubscriptionId = null;
    _pendingSubscriptionId = null;
    _subscriptionTargetFingerprint = null;
    _stages.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!sendUnsubscribe ||
        subscriptionId == null ||
        bridge.currentBridgeConnectionState !=
            BridgeConnectionState.connected) {
      return;
    }
    try {
      bridge.send(
        conversationContentUnsubscribe(
          requestId: _nextRequestId('unsubscribe'),
          subscriptionId: subscriptionId,
        ),
      );
    } catch (_) {
      // The socket is already unusable; connection handling owns recovery.
    }
  }

  void _scheduleRetry() {
    if (_disposed || !_canProcessContent || _retryTimer != null) return;
    final exponent = _retryAttempt > 8 ? 8 : _retryAttempt;
    final multiplier = 1 << exponent;
    final calculated = retryBaseDelay * multiplier;
    final delay = calculated > retryMaxDelay ? retryMaxDelay : calculated;
    _retryAttempt += 1;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _ensureSubscribed();
    });
  }

  void _restartSubscription() {
    _stopSubscription(sendUnsubscribe: true);
    _scheduleRetry();
  }

  String _nextRequestId(String operation) {
    _requestSequence += 1;
    return 'conversation-content-$operation-'
        '${DateTime.now().microsecondsSinceEpoch}-$_requestSequence';
  }

  static String _stageKey(ConversationContentEventMessage event) =>
      '${event.provider}\u0000${event.providerSessionId}\u0000${event.revision}';

  static bool _sameTarget(
    ConversationContentTarget? left,
    ConversationContentTarget? right,
  ) =>
      left?.provider == right?.provider &&
      left?.providerSessionId == right?.providerSessionId;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopSubscription(sendUnsubscribe: true);
    await Future.wait([
      if (_connectionSubscription != null) _connectionSubscription!.cancel(),
      if (_sessionListSubscription != null) _sessionListSubscription!.cancel(),
      if (_messageSubscription != null) _messageSubscription!.cancel(),
      if (_deliveryModeSubscription != null)
        _deliveryModeSubscription!.cancel(),
    ]);
    await _updatesController.close();
  }
}

class _SnapshotStage {
  _SnapshotStage({
    required this.provider,
    required this.providerSessionId,
    required this.revision,
    required this.entryCount,
    required this.pageCount,
    required this.hasEarlier,
    required this.sourceEntryCount,
  });

  final String provider;
  final String providerSessionId;
  final String revision;
  final int entryCount;
  final int pageCount;
  final bool hasEarlier;
  final int sourceEntryCount;
  final Map<int, List<ConversationContentWireEntry>> pages = {};
}
