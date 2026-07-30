import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../core/logger.dart';
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
  bool get supportsConversationSyncV2;
  bool get supportsConversationItemsById;
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
  bool get supportsConversationSyncV2 => bridge.supportsConversationSyncV2;

  @override
  bool get supportsConversationItemsById =>
      bridge.supportsConversationItemsById;

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

enum ConversationSyncCacheUpdateKind {
  started,
  catalog,
  status,
  timeline,
  readWatermark,
  priorityReady,
  completed,
  reset,
}

class ConversationSyncCacheUpdate {
  const ConversationSyncCacheUpdate({
    required this.kind,
    this.targetFingerprint,
    this.codexSourceId,
    this.provider,
    this.providerSessionId,
    this.revision,
    this.catalogUpserts = const [],
    this.catalogDestroyed = const [],
    this.statusChanges = const [],
    this.readWatermark,
    this.sequence,
    this.pageIndex,
    this.pageCount,
    this.timelineIndex,
    this.timelineCount,
    this.phase,
  });

  final ConversationSyncCacheUpdateKind kind;
  final String? targetFingerprint;
  final String? codexSourceId;
  final String? provider;
  final String? providerSessionId;
  final String? revision;
  final List<ConversationSyncV2CatalogEntry> catalogUpserts;
  final List<ConversationSyncV2Target> catalogDestroyed;
  final List<ConversationSyncV2Status> statusChanges;
  final ConversationSyncV2ReadWatermark? readWatermark;
  final int? sequence;
  final int? pageIndex;
  final int? pageCount;
  final int? timelineIndex;
  final int? timelineCount;
  final String? phase;
}

class ConversationTurnsPageLoadResult {
  const ConversationTurnsPageLoadResult({
    required this.loaded,
    required this.hasMore,
  });

  final bool loaded;
  final bool hasMore;
}

/// Maintains one foreground subscription to the Bridge-owned conversation
/// scheduler.
///
/// The phone never polls individual conversations. Snapshot pages are staged
/// directly in SQLite and atomically committed before cumulative ACK when v2 is
/// available. The bounded v1 in-memory stage remains only for old Bridges.
/// Background lifecycle states reject body events and unsubscribe, preserving
/// notification-only behavior.
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
  final StreamController<ConversationSyncCacheUpdate> _syncUpdatesController =
      StreamController<ConversationSyncCacheUpdate>.broadcast();
  final Map<String, _SnapshotStage> _stages = {};
  final Map<String, _PendingTurnsPage> _pendingTurnsPages = {};
  final Map<String, _PendingItemsPage> _pendingItemsPages = {};
  final Map<String, _PendingLatestTurnRepairPage>
  _pendingLatestTurnRepairPages = {};
  final Map<String, Future<ConversationTurnsPageLoadResult>>
  _historyPageFlights = {};
  final Set<Completer<void>> _subscriptionReadyWaiters = {};

  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<List<SessionInfo>>? _sessionListSubscription;
  StreamSubscription<LocalFeatureServerMessage>? _messageSubscription;
  StreamSubscription<ClientDeliveryModeStateMessage>? _deliveryModeSubscription;
  Timer? _retryTimer;

  ConversationContentTarget? _focused;
  String? _pendingSubscriptionId;
  String? _activeSubscriptionId;
  String? _activeSubscriptionRequestId;
  String? _subscriptionTargetFingerprint;
  String? _subscriptionBridgeInstanceId;
  bool _foreground = false;
  bool _started = false;
  bool _disposed = false;
  int _generation = 0;
  int _requestSequence = 0;
  int _retryAttempt = 0;
  int _highestV2CommittedSequence = 0;
  bool _v2PriorityBootstrapComplete = false;
  String? _v2RecoveryTargetFingerprint;
  Future<void> _v2MutationTail = Future<void>.value();

  Stream<ConversationContentCacheUpdate> get updates =>
      _updatesController.stream;
  Stream<ConversationSyncCacheUpdate> get syncUpdates =>
      _syncUpdatesController.stream;

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
      } else if (message is ConversationSyncV2EventMessage) {
        _handleV2Event(message);
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
        bridge.supportsConversationSyncV2
            ? conversationSyncV2Focus(
                requestId: _nextRequestId('focus'),
                subscriptionId: subscriptionId,
                focused: next == null
                    ? null
                    : ConversationSyncV2Target(
                        provider: next.provider,
                        providerSessionId: next.providerSessionId,
                      ),
              )
            : conversationContentFocus(
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

  Future<void> markConversationRead({
    required String provider,
    required String providerSessionId,
    DateTime? readAt,
  }) async {
    if (!bridge.supportsConversationSyncV2 || _disposed) return;
    final target = _cacheTarget;
    if (!target.isValid) return;
    final watermark = ConversationSyncV2ReadWatermark(
      provider: provider,
      providerSessionId: providerSessionId,
      readAt: (readAt ?? DateTime.now()).toUtc().toIso8601String(),
    );
    await cache.storeReadWatermark(target: target, watermark: watermark);
    if (_disposed || target.fingerprint != _cacheTarget.fingerprint) return;
    _syncUpdatesController.add(
      ConversationSyncCacheUpdate(
        kind: ConversationSyncCacheUpdateKind.readWatermark,
        targetFingerprint: target.fingerprint,
        provider: provider,
        providerSessionId: providerSessionId,
        readWatermark: watermark,
      ),
    );
    final subscriptionId = _activeSubscriptionId;
    if (subscriptionId == null || !_canProcessContent) return;
    try {
      bridge.send(
        conversationSyncV2Read(
          subscriptionId: subscriptionId,
          watermark: watermark,
        ),
      );
    } catch (_) {
      _handleTransportLoss();
    }
  }

  Future<ConversationTurnsPageLoadResult> loadOlderTurns({
    required String provider,
    required String providerSessionId,
    int limit = 5,
  }) {
    final flightKey = '$provider\u0000$providerSessionId';
    final existing = _historyPageFlights[flightKey];
    if (existing != null) return existing;
    late final Future<ConversationTurnsPageLoadResult> flight;
    flight =
        _loadOlderTurnsWithRetry(
          provider: provider,
          providerSessionId: providerSessionId,
          limit: limit,
        ).whenComplete(() {
          if (identical(_historyPageFlights[flightKey], flight)) {
            _historyPageFlights.remove(flightKey);
          }
        });
    _historyPageFlights[flightKey] = flight;
    return flight;
  }

  Future<ConversationTurnsPageLoadResult> _loadOlderTurnsWithRetry({
    required String provider,
    required String providerSessionId,
    required int limit,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _loadOlderTurnsOnce(
          provider: provider,
          providerSessionId: providerSessionId,
          limit: limit,
        );
      } on _ConversationPagingInterrupted {
        if (attempt > 0 || !_canProcessContent) rethrow;
        final scope = Object.hash(
          provider,
          providerSessionId,
        ).toUnsigned(32).toRadixString(16).padLeft(8, '0');
        logger.info(
          '[conversation_sync_v2] event=turns_page_retry '
          'reason=subscription_replaced scope=$scope',
        );
        await _waitForActiveSubscription(const Duration(seconds: 8));
      }
    }
    return const ConversationTurnsPageLoadResult(loaded: false, hasMore: true);
  }

  Future<ConversationTurnsPageLoadResult> _loadOlderTurnsOnce({
    required String provider,
    required String providerSessionId,
    required int limit,
  }) async {
    if (!bridge.supportsConversationSyncV2 || !_canProcessContent) {
      return const ConversationTurnsPageLoadResult(
        loaded: false,
        hasMore: false,
      );
    }
    final target = _cacheTarget;
    final snapshot = await cache.loadConversationWindow(
      target: target,
      provider: provider,
      providerSessionId: providerSessionId,
    );
    if (snapshot == null) {
      return const ConversationTurnsPageLoadResult(
        loaded: false,
        hasMore: false,
      );
    }
    if (!snapshot.latestTurnComplete) {
      return _repairLatestTurnGap(
        target: target,
        snapshot: snapshot,
        provider: provider,
        providerSessionId: providerSessionId,
      );
    }
    if (!snapshot.hasEarlier) {
      return const ConversationTurnsPageLoadResult(
        loaded: false,
        hasMore: false,
      );
    }
    final subscriptionId = _activeSubscriptionId;
    if (subscriptionId == null ||
        target.fingerprint != _cacheTarget.fingerprint ||
        !_canProcessContent) {
      return const ConversationTurnsPageLoadResult(
        loaded: false,
        hasMore: true,
      );
    }
    final requestId = _nextRequestId('turns');
    final completer = Completer<ConversationTurnsPageLoadResult>();
    final pending = _PendingTurnsPage(
      generation: _generation,
      targetFingerprint: target.fingerprint,
      provider: provider,
      providerSessionId: providerSessionId,
      completer: completer,
    );
    _pendingTurnsPages[requestId] = pending;
    try {
      bridge.send(
        conversationSyncV2TurnsPage(
          requestId: requestId,
          subscriptionId: subscriptionId,
          target: ConversationSyncV2Target(
            provider: provider,
            providerSessionId: providerSessionId,
          ),
          cursor: snapshot.turnsNextCursor,
          limit: limit.clamp(1, 20),
          itemsView: 'summary',
        ),
      );
      return await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      if (identical(_pendingTurnsPages[requestId], pending)) {
        _pendingTurnsPages.remove(requestId);
      }
    }
  }

  Future<ConversationTurnsPageLoadResult> _repairLatestTurnGap({
    required SessionCatalogCacheTarget target,
    required ConversationHotWindowSnapshot snapshot,
    required String provider,
    required String providerSessionId,
  }) async {
    const maximumPages = 32;
    const maximumBytes = 8 * 1024 * 1024;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var current = snapshot;
    var transferredBytes = 0;
    for (var page = 0; page < maximumPages; page++) {
      if (current.latestTurnComplete) {
        return ConversationTurnsPageLoadResult(
          loaded: true,
          hasMore: current.hasEarlier,
        );
      }
      final gap = current.latestTurnGap;
      if (gap == null) {
        throw StateError(
          'Incomplete latest conversation turn has no repair directive.',
        );
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Conversation latest turn repair exceeded its total deadline.',
          const Duration(seconds: 30),
        );
      }
      final useItemsPage = gap.repair == 'items_page' && gap.turnId != null;
      final repaired = await _requestLatestTurnRepairPage(
        target: target,
        snapshot: current,
        provider: provider,
        providerSessionId: providerSessionId,
        repair: useItemsPage ? 'items_page' : 'turns_page',
        timeout: remaining < const Duration(seconds: 15)
            ? remaining
            : const Duration(seconds: 15),
        maximumBytes: maximumBytes - transferredBytes,
      );
      transferredBytes += repaired.pageBytes;
      current = repaired.snapshot;
      if (!useItemsPage || current.latestTurnComplete) {
        return ConversationTurnsPageLoadResult(
          loaded: true,
          hasMore: current.hasEarlier,
        );
      }
      if (transferredBytes >= maximumBytes) {
        throw StateError(
          'Conversation latest turn repair exceeded its byte budget.',
        );
      }
    }
    throw StateError(
      'Conversation latest turn repair exceeded its page bound.',
    );
  }

  Future<_LatestTurnRepairPageResult> _requestLatestTurnRepairPage({
    required SessionCatalogCacheTarget target,
    required ConversationHotWindowSnapshot snapshot,
    required String provider,
    required String providerSessionId,
    required String repair,
    required Duration timeout,
    required int maximumBytes,
  }) async {
    final subscriptionId = _activeSubscriptionId;
    if (subscriptionId == null ||
        target.fingerprint != _cacheTarget.fingerprint ||
        !_canProcessContent) {
      throw const _ConversationPagingInterrupted();
    }
    final gap = snapshot.latestTurnGap!;
    final requestId = _nextRequestId('latest-turn');
    final completer = Completer<_LatestTurnRepairPageResult>();
    final pending = _PendingLatestTurnRepairPage(
      generation: _generation,
      targetFingerprint: target.fingerprint,
      provider: provider,
      providerSessionId: providerSessionId,
      revision: snapshot.revision,
      repair: repair,
      turnId: repair == 'items_page' ? gap.turnId : null,
      maximumBytes: maximumBytes,
      completer: completer,
    );
    _pendingLatestTurnRepairPages[requestId] = pending;
    try {
      final targetMessage = ConversationSyncV2Target(
        provider: provider,
        providerSessionId: providerSessionId,
      );
      bridge.send(
        repair == 'items_page'
            ? conversationSyncV2ItemsPage(
                requestId: requestId,
                subscriptionId: subscriptionId,
                target: targetMessage,
                turnId: gap.turnId,
                cursor: snapshot.latestTurnGapCursor,
                limit: 200,
                sortDirection: 'asc',
              )
            : conversationSyncV2TurnsPage(
                requestId: requestId,
                subscriptionId: subscriptionId,
                target: targetMessage,
                // A current-turn repair must never consume the older-turn
                // cursor. A null cursor asks the provider for its newest page.
                cursor: null,
                limit: 5,
                sortDirection: 'desc',
                itemsView: 'full',
              ),
      );
      return await completer.future.timeout(timeout);
    } finally {
      if (identical(_pendingLatestTurnRepairPages[requestId], pending)) {
        _pendingLatestTurnRepairPages.remove(requestId);
      }
    }
  }

  Future<void> _waitForActiveSubscription(Duration timeout) {
    if (_activeSubscriptionId != null && _canProcessContent) {
      return Future<void>.value();
    }
    if (_disposed || !_canProcessContent) {
      return Future<void>.error(const _ConversationPagingInterrupted());
    }
    final completer = Completer<void>();
    _subscriptionReadyWaiters.add(completer);
    return completer.future
        .timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'Conversation sync subscription did not recover in time.',
            timeout,
          ),
        )
        .whenComplete(() => _subscriptionReadyWaiters.remove(completer));
  }

  void _notifySubscriptionReady() {
    if (_activeSubscriptionId == null || !_canProcessContent) return;
    final waiters = _subscriptionReadyWaiters.toList(growable: false);
    _subscriptionReadyWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _failSubscriptionReadyWaiters(Object error) {
    final waiters = _subscriptionReadyWaiters.toList(growable: false);
    _subscriptionReadyWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }

  Future<List<HistoryToolDetail>?> loadToolDetails({
    required String provider,
    required String providerSessionId,
    required HistoryToolDetailGap gap,
    required List<String> toolUseIds,
  }) async {
    final turnId = gap.turnId;
    final normalizedIds = toolUseIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && value.length <= 256)
        .toSet()
        .take(8)
        .toList(growable: false);
    if (turnId == null ||
        normalizedIds.isEmpty ||
        !bridge.supportsConversationSyncV2 ||
        !_canProcessContent) {
      return null;
    }
    final target = _cacheTarget;
    final subscriptionId = _activeSubscriptionId;
    if (subscriptionId == null ||
        target.fingerprint != _cacheTarget.fingerprint ||
        !_canProcessContent) {
      return null;
    }
    final requestId = _nextRequestId('items');
    final completer = Completer<List<HistoryToolDetail>?>();
    _pendingItemsPages[requestId] = _PendingItemsPage(
      generation: _generation,
      targetFingerprint: target.fingerprint,
      provider: provider,
      providerSessionId: providerSessionId,
      turnId: turnId,
      toolUseIds: normalizedIds,
      completer: completer,
    );
    try {
      bridge.send(
        conversationSyncV2ItemsPage(
          requestId: requestId,
          subscriptionId: subscriptionId,
          target: ConversationSyncV2Target(
            provider: provider,
            providerSessionId: providerSessionId,
          ),
          turnId: turnId,
          toolUseIds: bridge.supportsConversationItemsById
              ? normalizedIds
              : null,
          limit: 200,
        ),
      );
      return await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      _pendingItemsPages.remove(requestId);
    }
  }

  bool get _canProcessContent =>
      _foreground &&
      bridge.currentBridgeConnectionState == BridgeConnectionState.connected &&
      bridge.desiredClientDeliveryMode ==
          BridgeClientDeliveryMode.interactive &&
      (bridge.supportsConversationSyncV2 ||
          bridge.supportsConversationContentEvents) &&
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
    _stopSubscription(sendUnsubscribe: true);
  }

  void _handleTransportLoss() {
    _generation += 1;
    _pendingSubscriptionId = null;
    _activeSubscriptionId = null;
    _activeSubscriptionRequestId = null;
    _subscriptionTargetFingerprint = null;
    _subscriptionBridgeInstanceId = null;
    _highestV2CommittedSequence = 0;
    _v2PriorityBootstrapComplete = false;
    _failPendingTurnsPages(const _ConversationPagingInterrupted());
    _failPendingItemsPages(
      StateError('Conversation item paging was interrupted.'),
    );
    _failPendingLatestTurnRepairPages(const _ConversationPagingInterrupted());
    _stages.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
  }

  void _ensureSubscribed() {
    final target = _cacheTarget;
    final targetFingerprint = target.fingerprint;
    final bridgeInstanceId = bridge.bridgeInstanceId;
    final hasSubscription =
        _pendingSubscriptionId != null || _activeSubscriptionId != null;
    if (hasSubscription &&
        (_subscriptionTargetFingerprint != targetFingerprint ||
            _subscriptionBridgeInstanceId != bridgeInstanceId)) {
      final sameBridge =
          _subscriptionBridgeInstanceId != null &&
          _subscriptionBridgeInstanceId == bridgeInstanceId;
      _stopSubscription(sendUnsubscribe: sameBridge);
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
    _v2PriorityBootstrapComplete = false;
    final requestId = _nextRequestId('subscribe');
    _pendingSubscriptionId = requestId;
    _subscriptionTargetFingerprint = targetFingerprint;
    _subscriptionBridgeInstanceId = bridgeInstanceId;
    if (bridge.supportsConversationSyncV2) {
      unawaited(_subscribeV2(generation, requestId, target));
      return;
    }
    unawaited(
      cache
          .knownConversationRevisions(target)
          .then((knownRevisions) {
            if (_disposed ||
                generation != _generation ||
                _pendingSubscriptionId != requestId ||
                !_canProcessContent ||
                _subscriptionTargetFingerprint != _cacheTarget.fingerprint ||
                _subscriptionBridgeInstanceId != bridge.bridgeInstanceId ||
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

  Future<void> _subscribeV2(
    int generation,
    String requestId,
    SessionCatalogCacheTarget target,
  ) async {
    try {
      final values = await Future.wait<Object>([
        cache.loadConversationSyncState(target),
        cache.knownConversationRevisions(target, limit: 512),
        cache.loadReadWatermarks(target, limit: 512),
      ]);
      if (_disposed ||
          generation != _generation ||
          _pendingSubscriptionId != requestId ||
          !_canProcessContent ||
          !bridge.supportsConversationSyncV2 ||
          target.fingerprint != _cacheTarget.fingerprint ||
          _subscriptionBridgeInstanceId != bridge.bridgeInstanceId) {
        return;
      }
      final state = values[0] as ConversationSyncCacheState;
      final revisions = values[1] as List<ConversationContentCursor>;
      final watermarks = values[2] as List<ConversationSyncV2ReadWatermark>;
      bridge.send(
        conversationSyncV2Subscribe(
          requestId: requestId,
          catalogState: state.catalogState,
          statusState: state.statusState,
          threadContentStates: revisions
              .map(
                (cursor) => ConversationSyncV2ThreadState(
                  provider: cursor.provider,
                  providerSessionId: cursor.providerSessionId,
                  revision: cursor.revision,
                ),
              )
              .toList(growable: false),
          readWatermarks: watermarks,
          focused: _focused == null
              ? null
              : ConversationSyncV2Target(
                  provider: _focused!.provider,
                  providerSessionId: _focused!.providerSessionId,
                ),
        ),
      );
      logger.info(
        '[conversation_sync_v2] event=subscribe_sent '
        'generation=$generation progress=80 '
        'knownRevisions=${revisions.length} '
        'readWatermarks=${watermarks.length}',
      );
    } catch (error) {
      logger.warning(
        '[conversation_sync_v2] event=subscribe_failed '
        'generation=$generation error=${error.runtimeType}',
      );
      if (generation == _generation) {
        _pendingSubscriptionId = null;
        _scheduleRetry();
      }
    }
  }

  void _handleEvent(ConversationContentEventMessage event) {
    if (bridge.supportsConversationSyncV2) return;
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
        _notifySubscriptionReady();
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

  void _handleV2Event(ConversationSyncV2EventMessage event) {
    if (!bridge.supportsConversationSyncV2 ||
        !_canProcessContent ||
        event.bridgeInstanceId != bridge.bridgeInstanceId ||
        event.codexSourceId != (bridge.codexSourceId ?? 'legacy') ||
        _subscriptionTargetFingerprint != _cacheTarget.fingerprint ||
        (event.subscriptionId != _activeSubscriptionId &&
            event.subscriptionId != _pendingSubscriptionId)) {
      return;
    }
    final generation = _generation;
    final target = _cacheTarget;
    _v2MutationTail = _v2MutationTail
        .then((_) => _commitV2Event(event, generation, target))
        .catchError(
          (Object error) =>
              _recoverFromV2CommitFailure(event, generation, target, error),
        );
  }

  Future<void> _recoverFromV2CommitFailure(
    ConversationSyncV2EventMessage event,
    int generation,
    SessionCatalogCacheTarget target,
    Object error,
  ) async {
    if (!_isV2Current(event, generation, target)) return;

    final targetToken = target.fingerprint.hashCode
        .toUnsigned(32)
        .toRadixString(16)
        .padLeft(8, '0');
    final threadRevisionMismatch =
        error is _ConversationTimelineBaseRevisionMismatch;
    final streamContinuityFailure =
        error is _ConversationSyncSequenceGap ||
        error is _ConversationSyncBeginMismatch;
    var recovery = threadRevisionMismatch
        ? 'thread_reset'
        : streamContinuityFailure
        ? 'stream_retry'
        : 'retry';

    if (!threadRevisionMismatch &&
        !streamContinuityFailure &&
        _v2RecoveryTargetFingerprint != target.fingerprint) {
      _v2RecoveryTargetFingerprint = target.fingerprint;
      try {
        await cache.clearTarget(target);
        recovery = 'target_reset';
      } catch (clearError) {
        recovery = 'target_reset_failed';
        logger.warning(
          '[conversation_sync_v2] event=cache_reset '
          'generation=$generation target=$targetToken '
          'error=${clearError.runtimeType}',
        );
      }
    }

    logger.warning(
      '[conversation_sync_v2] event=${event.event.name} '
      'sequence=${event.sequence} generation=$generation '
      'target=$targetToken error=${error.runtimeType} recovery=$recovery',
    );
    if (_isV2Current(event, generation, target)) {
      _restartSubscription();
    }
  }

  Future<void> _commitV2Event(
    ConversationSyncV2EventMessage event,
    int generation,
    SessionCatalogCacheTarget target,
  ) async {
    if (!_isV2Current(event, generation, target)) return;
    if (event.sequence <= _highestV2CommittedSequence) {
      _sendV2Ack(event.subscriptionId, _highestV2CommittedSequence);
      return;
    }
    if (event.sequence != _highestV2CommittedSequence + 1) {
      throw _ConversationSyncSequenceGap(
        expected: _highestV2CommittedSequence + 1,
        actual: event.sequence,
      );
    }
    ConversationSyncCacheUpdate? publish;
    switch (event.event) {
      case ConversationSyncV2EventKind.syncBegin:
        final pendingRequestId = _pendingSubscriptionId;
        if (pendingRequestId != null) {
          if (event.requestId != pendingRequestId) {
            throw const _ConversationSyncBeginMismatch();
          }
          _activeSubscriptionId = event.subscriptionId;
          _activeSubscriptionRequestId = pendingRequestId;
          _pendingSubscriptionId = null;
          await cache.beginConversationSync(
            target: target,
            subscriptionId: event.subscriptionId,
          );
          _notifySubscriptionReady();
          publish = ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.started,
            targetFingerprint: target.fingerprint,
          );
        } else if (event.requestId != _activeSubscriptionRequestId) {
          throw const _ConversationSyncBeginMismatch();
        }
      case ConversationSyncV2EventKind.catalogChanges:
        await cache.applyConversationCatalogPage(
          target: target,
          codexSourceId: event.codexSourceId,
          catalogState: event.catalogState!,
          pageIndex: event.pageIndex!,
          pageCount: event.pageCount!,
          created: event.created,
          updated: event.updated,
          destroyed: event.destroyed,
        );
        publish = ConversationSyncCacheUpdate(
          kind: ConversationSyncCacheUpdateKind.catalog,
          targetFingerprint: target.fingerprint,
          codexSourceId: event.codexSourceId,
          catalogUpserts: List.unmodifiable([
            ...event.created,
            ...event.updated,
          ]),
          catalogDestroyed: event.destroyed,
        );
      case ConversationSyncV2EventKind.statusChanges:
        await cache.applyConversationStatusPage(
          target: target,
          statusState: event.statusState!,
          pageIndex: event.pageIndex!,
          pageCount: event.pageCount!,
          changes: event.statusChanges,
        );
        publish = ConversationSyncCacheUpdate(
          kind: ConversationSyncCacheUpdateKind.status,
          targetFingerprint: target.fingerprint,
          statusChanges: event.statusChanges,
        );
      case ConversationSyncV2EventKind.timelinePage:
        final committed = await cache.stageConversationTimelinePage(
          target: target,
          subscriptionId: event.subscriptionId,
          provider: event.provider!,
          providerSessionId: event.providerSessionId!,
          revision: event.revision!,
          baseRevision: event.baseRevision,
          mode: event.mode!,
          pageIndex: event.pageIndex!,
          pageCount: event.pageCount!,
          entries: event.entries,
          deletes: event.deletes,
          hasEarlier: event.hasEarlier!,
          turnsNextCursor: event.turnsNextCursor,
          latestTurnComplete: event.latestTurnComplete ?? true,
          latestTurnGap: event.latestTurnGap,
          sourceEntryCount: event.sourceEntryCount!,
        );
        if (!committed.baseRevisionMatched) {
          await cache.deleteConversationWindow(
            target: target,
            provider: event.provider!,
            providerSessionId: event.providerSessionId!,
          );
          throw const _ConversationTimelineBaseRevisionMismatch();
        }
        if (committed.windowCommitted) {
          _updatesController.add(
            ConversationContentCacheUpdate(
              provider: event.provider!,
              providerSessionId: event.providerSessionId!,
              revision: event.revision!,
            ),
          );
          publish = ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.timeline,
            targetFingerprint: target.fingerprint,
            provider: event.provider,
            providerSessionId: event.providerSessionId,
            revision: event.revision,
          );
        }
      case ConversationSyncV2EventKind.syncCheckpoint:
        if (event.phase == 'priority') {
          await cache.markConversationPriorityReady(target);
          publish = ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.priorityReady,
            targetFingerprint: target.fingerprint,
          );
        }
      case ConversationSyncV2EventKind.syncComplete:
        await cache.completeConversationSync(
          target: target,
          nextState: event.nextState!,
        );
        publish = ConversationSyncCacheUpdate(
          kind: ConversationSyncCacheUpdateKind.completed,
          targetFingerprint: target.fingerprint,
        );
      case ConversationSyncV2EventKind.syncReset:
        await cache.resetConversationSyncScope(
          target: target,
          scope: event.scope!,
          thread: event.target,
        );
        publish = ConversationSyncCacheUpdate(
          kind: ConversationSyncCacheUpdateKind.reset,
          targetFingerprint: target.fingerprint,
          provider: event.target?.provider,
          providerSessionId: event.target?.providerSessionId,
        );
      case ConversationSyncV2EventKind.turnsPageResponse:
        final latestTurnRequest = event.requestId == null
            ? null
            : _pendingLatestTurnRepairPages[event.requestId!];
        if (latestTurnRequest != null &&
            latestTurnRequest.repair == 'turns_page' &&
            latestTurnRequest.generation == generation &&
            latestTurnRequest.targetFingerprint == target.fingerprint &&
            latestTurnRequest.provider == event.provider &&
            latestTurnRequest.providerSessionId == event.providerSessionId) {
          final rawMessages = event.pageRawMessages();
          final pageBytes = utf8.encode(jsonEncode(rawMessages)).length;
          if (pageBytes > latestTurnRequest.maximumBytes) {
            if (!latestTurnRequest.completer.isCompleted) {
              latestTurnRequest.completer.completeError(
                StateError(
                  'Conversation latest turn repair exceeded its byte budget.',
                ),
              );
            }
          } else {
            ConversationHotWindowSnapshot? snapshot;
            try {
              snapshot = await cache.replaceConversationLatestTurnsRepairPage(
                target: target,
                provider: event.provider!,
                providerSessionId: event.providerSessionId!,
                expectedRevision: latestTurnRequest.revision,
                rawMessages: rawMessages,
                turnsNextCursor: event.nextCursor,
              );
            } catch (error, stackTrace) {
              // A local repair budget/database failure must leave the existing
              // incomplete window intact. It is scoped to this explicit
              // request and must not reach the generic v2 recovery path, which
              // clears the whole rebuildable target.
              if (!latestTurnRequest.completer.isCompleted) {
                latestTurnRequest.completer.completeError(error, stackTrace);
              }
            }
            if (snapshot == null || !snapshot.latestTurnComplete) {
              if (!latestTurnRequest.completer.isCompleted) {
                latestTurnRequest.completer.completeError(
                  const _ConversationPagingInterrupted(),
                );
              }
            } else {
              if (!latestTurnRequest.completer.isCompleted) {
                latestTurnRequest.completer.complete(
                  _LatestTurnRepairPageResult(
                    snapshot: snapshot,
                    pageBytes: pageBytes,
                  ),
                );
              }
              _updatesController.add(
                ConversationContentCacheUpdate(
                  provider: event.provider!,
                  providerSessionId: event.providerSessionId!,
                  revision:
                      '${snapshot.revision}:'
                      '${snapshot.entries.length}:'
                      '${snapshot.cachedAt.microsecondsSinceEpoch}',
                ),
              );
              publish = ConversationSyncCacheUpdate(
                kind: ConversationSyncCacheUpdateKind.timeline,
                targetFingerprint: target.fingerprint,
                provider: event.provider,
                providerSessionId: event.providerSessionId,
                revision: snapshot.revision,
              );
            }
          }
        } else {
          final request = event.requestId == null
              ? null
              : _pendingTurnsPages[event.requestId!];
          if (request != null &&
              request.generation == generation &&
              request.targetFingerprint == target.fingerprint &&
              request.provider == event.provider &&
              request.providerSessionId == event.providerSessionId) {
            final snapshot = await cache.prependConversationTurnsPage(
              target: target,
              provider: event.provider!,
              providerSessionId: event.providerSessionId!,
              rawMessages: event.pageRawMessages(),
              nextCursor: event.nextCursor,
            );
            if (!request.completer.isCompleted) {
              request.completer.complete(
                ConversationTurnsPageLoadResult(
                  loaded: snapshot != null,
                  hasMore: event.nextCursor != null,
                ),
              );
            }
            if (snapshot != null) {
              _updatesController.add(
                ConversationContentCacheUpdate(
                  provider: event.provider!,
                  providerSessionId: event.providerSessionId!,
                  revision:
                      '${snapshot.revision}:'
                      '${snapshot.entries.length}:'
                      '${snapshot.cachedAt.microsecondsSinceEpoch}',
                ),
              );
              publish = ConversationSyncCacheUpdate(
                kind: ConversationSyncCacheUpdateKind.timeline,
                targetFingerprint: target.fingerprint,
                provider: event.provider,
                providerSessionId: event.providerSessionId,
                revision: snapshot.revision,
              );
            }
          }
        }
      case ConversationSyncV2EventKind.itemsPageResponse:
        final latestTurnRequest = event.requestId == null
            ? null
            : _pendingLatestTurnRepairPages[event.requestId!];
        if (latestTurnRequest != null &&
            latestTurnRequest.repair == 'items_page' &&
            latestTurnRequest.generation == generation &&
            latestTurnRequest.targetFingerprint == target.fingerprint &&
            latestTurnRequest.provider == event.provider &&
            latestTurnRequest.providerSessionId == event.providerSessionId &&
            latestTurnRequest.turnId == event.turnId) {
          final rawMessages = event.pageRawMessages();
          final pageBytes = utf8.encode(jsonEncode(rawMessages)).length;
          if (pageBytes > latestTurnRequest.maximumBytes) {
            if (!latestTurnRequest.completer.isCompleted) {
              latestTurnRequest.completer.completeError(
                StateError(
                  'Conversation latest turn repair exceeded its byte budget.',
                ),
              );
            }
          } else {
            ConversationHotWindowSnapshot? snapshot;
            try {
              snapshot = await cache.mergeConversationLatestTurnItemsPage(
                target: target,
                provider: event.provider!,
                providerSessionId: event.providerSessionId!,
                expectedRevision: latestTurnRequest.revision,
                expectedTurnId: latestTurnRequest.turnId!,
                rawMessages: rawMessages,
                nextCursor: event.nextCursor,
              );
            } catch (error, stackTrace) {
              // Keep the previous gap/cursor committed. This is an explicit
              // page failure, not corruption of the subscription state.
              if (!latestTurnRequest.completer.isCompleted) {
                latestTurnRequest.completer.completeError(error, stackTrace);
              }
            }
            if (snapshot == null) {
              if (!latestTurnRequest.completer.isCompleted) {
                latestTurnRequest.completer.completeError(
                  const _ConversationPagingInterrupted(),
                );
              }
            } else {
              if (!latestTurnRequest.completer.isCompleted) {
                latestTurnRequest.completer.complete(
                  _LatestTurnRepairPageResult(
                    snapshot: snapshot,
                    pageBytes: pageBytes,
                  ),
                );
              }
              _updatesController.add(
                ConversationContentCacheUpdate(
                  provider: event.provider!,
                  providerSessionId: event.providerSessionId!,
                  revision:
                      '${snapshot.revision}:'
                      '${snapshot.entries.length}:'
                      '${snapshot.cachedAt.microsecondsSinceEpoch}',
                ),
              );
              publish = ConversationSyncCacheUpdate(
                kind: ConversationSyncCacheUpdateKind.timeline,
                targetFingerprint: target.fingerprint,
                provider: event.provider,
                providerSessionId: event.providerSessionId,
                revision: snapshot.revision,
              );
            }
          }
        } else {
          final request = event.requestId == null
              ? null
              : _pendingItemsPages[event.requestId!];
          if (request != null &&
              request.generation == generation &&
              request.targetFingerprint == target.fingerprint &&
              request.provider == event.provider &&
              request.providerSessionId == event.providerSessionId &&
              request.turnId == event.turnId) {
            final details = _historyToolDetailsFromPage(
              event.pageRawMessages(),
              request.toolUseIds,
            );
            if (!request.completer.isCompleted) {
              request.completer.complete(details);
            }
          }
        }
      case ConversationSyncV2EventKind.focusApplied:
      case ConversationSyncV2EventKind.unsubscribed:
      // These responses do not mutate the hot cache in this service. Their
      // sequence still participates in cumulative flow control.
      case ConversationSyncV2EventKind.error:
        final pageRequest = event.requestId == null
            ? null
            : _pendingTurnsPages[event.requestId!];
        if (pageRequest != null && !pageRequest.completer.isCompleted) {
          pageRequest.completer.completeError(
            StateError(event.error ?? 'Conversation history page failed.'),
          );
        }
        final itemRequest = event.requestId == null
            ? null
            : _pendingItemsPages[event.requestId!];
        if (itemRequest != null && !itemRequest.completer.isCompleted) {
          itemRequest.completer.completeError(
            StateError(event.error ?? 'Conversation item page failed.'),
          );
        }
        final latestTurnRequest = event.requestId == null
            ? null
            : _pendingLatestTurnRepairPages[event.requestId!];
        if (latestTurnRequest != null &&
            !latestTurnRequest.completer.isCompleted) {
          latestTurnRequest.completer.completeError(
            StateError(
              event.error ?? 'Conversation latest turn repair failed.',
            ),
          );
        }
        if (event.requestId == _pendingSubscriptionId) {
          throw StateError(event.error ?? 'Conversation sync failed.');
        }
    }
    if (!_isV2Current(event, generation, target)) return;
    _highestV2CommittedSequence = event.sequence;
    _sendV2Ack(event.subscriptionId, event.sequence);
    final pageIndex = event.pageIndex;
    final pageCount = event.pageCount;
    final page = pageIndex == null || pageCount == null
        ? ''
        : ' page=${pageIndex + 1}/$pageCount';
    final timeline = event.timelineIndex == null || event.timelineCount == null
        ? ''
        : ' timeline=${event.timelineIndex! + 1}/${event.timelineCount}';
    final phase = event.phase == null ? '' : ' phase=${event.phase}';
    final progress = _v2CommitProgress(event);
    final scope = event.providerSessionId == null
        ? ''
        : ' scope=${Object.hash(event.provider, event.providerSessionId).toUnsigned(32).toRadixString(16).padLeft(8, '0')}';
    final progressScope =
        event.event == ConversationSyncV2EventKind.timelinePage
        ? event.timelineCount == null
              ? ' pageScope=thread progressScope=unavailable'
              : ' pageScope=thread progressScope=${event.phase ?? 'timeline'}_batch'
        : '';
    logger.info(
      '[conversation_sync_v2] event=commit '
      'kind=${event.event.name} sequence=${event.sequence} '
      'generation=$generation${progress == null ? '' : ' progress=$progress'}'
      '$timeline$page$phase$scope$progressScope',
    );
    final progressUpdate =
        publish ??
        (event.event == ConversationSyncV2EventKind.timelinePage
            ? ConversationSyncCacheUpdate(
                kind: ConversationSyncCacheUpdateKind.timeline,
                targetFingerprint: target.fingerprint,
                provider: event.provider,
                providerSessionId: event.providerSessionId,
                revision: event.revision,
              )
            : null);
    if (progressUpdate != null) {
      _syncUpdatesController.add(
        ConversationSyncCacheUpdate(
          kind: progressUpdate.kind,
          targetFingerprint: progressUpdate.targetFingerprint,
          codexSourceId: progressUpdate.codexSourceId,
          provider: progressUpdate.provider,
          providerSessionId: progressUpdate.providerSessionId,
          revision: progressUpdate.revision,
          catalogUpserts: progressUpdate.catalogUpserts,
          catalogDestroyed: progressUpdate.catalogDestroyed,
          statusChanges: progressUpdate.statusChanges,
          readWatermark: progressUpdate.readWatermark,
          sequence: event.sequence,
          pageIndex: event.pageIndex,
          pageCount: event.pageCount,
          timelineIndex: event.timelineIndex,
          timelineCount: event.timelineCount,
          phase: event.phase,
        ),
      );
    }
    final reachedStableCheckpoint =
        (event.event == ConversationSyncV2EventKind.syncCheckpoint &&
            event.phase == 'priority') ||
        event.event == ConversationSyncV2EventKind.syncComplete;
    if (reachedStableCheckpoint) {
      _v2PriorityBootstrapComplete = true;
      _retryAttempt = 0;
      _v2RecoveryTargetFingerprint = null;
    }
  }

  int? _v2CommitProgress(ConversationSyncV2EventMessage event) {
    if (_v2PriorityBootstrapComplete) return null;
    double pageProgress(double start, double span) {
      final pageIndex = event.pageIndex;
      final pageCount = event.pageCount;
      if (pageIndex == null || pageCount == null || pageCount <= 0) {
        return start;
      }
      return start + span * ((pageIndex + 1) / pageCount).clamp(0, 1);
    }

    double timelineProgress() {
      final timelineIndex = event.timelineIndex;
      final timelineCount = event.timelineCount;
      if (event.phase != 'priority' ||
          timelineIndex == null ||
          timelineCount == null ||
          timelineCount <= 0) {
        return 90;
      }
      final pageIndex = event.pageIndex ?? 0;
      final pageCount = event.pageCount ?? 1;
      final withinTimeline = ((pageIndex + 1) / pageCount).clamp(0, 1);
      final completed = (timelineIndex + withinTimeline) / timelineCount;
      return 90 + 6 * completed.clamp(0, 1);
    }

    return switch (event.event) {
      ConversationSyncV2EventKind.syncBegin => 82,
      ConversationSyncV2EventKind.catalogChanges => pageProgress(82, 4).round(),
      ConversationSyncV2EventKind.statusChanges => pageProgress(86, 4).round(),
      ConversationSyncV2EventKind.timelinePage => timelineProgress().round(),
      ConversationSyncV2EventKind.syncCheckpoint
          when event.phase == 'priority' =>
        97,
      ConversationSyncV2EventKind.syncComplete => 98,
      ConversationSyncV2EventKind.syncReset => 80,
      ConversationSyncV2EventKind.turnsPageResponse ||
      ConversationSyncV2EventKind.itemsPageResponse ||
      ConversationSyncV2EventKind.focusApplied ||
      ConversationSyncV2EventKind.unsubscribed ||
      ConversationSyncV2EventKind.error ||
      ConversationSyncV2EventKind.syncCheckpoint => null,
    };
  }

  bool _isV2Current(
    ConversationSyncV2EventMessage event,
    int generation,
    SessionCatalogCacheTarget target,
  ) =>
      !_disposed &&
      generation == _generation &&
      target.fingerprint == _cacheTarget.fingerprint &&
      event.subscriptionId ==
          (_activeSubscriptionId ?? _pendingSubscriptionId) &&
      _canProcessContent;

  void _sendV2Ack(String subscriptionId, int sequence) {
    try {
      bridge.send(
        conversationSyncV2Ack(
          subscriptionId: subscriptionId,
          sequence: sequence,
        ),
      );
    } catch (_) {
      _handleTransportLoss();
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
        latestTurnComplete: true,
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
    _activeSubscriptionRequestId = null;
    _subscriptionTargetFingerprint = null;
    _subscriptionBridgeInstanceId = null;
    _highestV2CommittedSequence = 0;
    _v2PriorityBootstrapComplete = false;
    _failPendingTurnsPages(const _ConversationPagingInterrupted());
    _failPendingItemsPages(
      StateError('Conversation item paging was interrupted.'),
    );
    _failPendingLatestTurnRepairPages(const _ConversationPagingInterrupted());
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
        bridge.supportsConversationSyncV2
            ? conversationSyncV2Unsubscribe(
                requestId: _nextRequestId('unsubscribe'),
                subscriptionId: subscriptionId,
              )
            : conversationContentUnsubscribe(
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

  static List<HistoryToolDetail>? _historyToolDetailsFromPage(
    List<Map<String, dynamic>> rawMessages,
    List<String> requestedIds,
  ) {
    final requested = requestedIds.toSet();
    final details = <String, HistoryToolDetail>{};
    for (final raw in rawMessages) {
      final message = ServerMessage.fromJson(raw);
      if (message is HistoryToolDetailsMessage) {
        for (final detail in message.details) {
          if (requested.contains(detail.toolUseId)) {
            details[detail.toolUseId] = detail;
          }
        }
        continue;
      }
      if (message is AssistantServerMessage) {
        for (final content in message.message.content) {
          if (content is! ToolUseContent || !requested.contains(content.id)) {
            continue;
          }
          final existing = details[content.id];
          details[content.id] = HistoryToolDetail(
            toolUseId: content.id,
            toolName: content.name,
            input: content.input,
            result: existing?.result,
          );
        }
        continue;
      }
      if (message is ToolResultMessage &&
          requested.contains(message.toolUseId)) {
        final existing = details[message.toolUseId];
        details[message.toolUseId] = HistoryToolDetail(
          toolUseId: message.toolUseId,
          toolName: existing?.toolName ?? message.toolName ?? 'Tool',
          input: existing?.input ?? const {},
          result: message,
        );
      }
    }
    if (details.isEmpty) return null;
    return List.unmodifiable([
      for (final toolUseId in requestedIds) ?details[toolUseId],
    ]);
  }

  void _failPendingTurnsPages(Object error) {
    for (final request in _pendingTurnsPages.values) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
    _pendingTurnsPages.clear();
  }

  void _failPendingItemsPages(Object error) {
    for (final request in _pendingItemsPages.values) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
    _pendingItemsPages.clear();
  }

  void _failPendingLatestTurnRepairPages(Object error) {
    for (final request in _pendingLatestTurnRepairPages.values) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
    _pendingLatestTurnRepairPages.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failSubscriptionReadyWaiters(
      StateError('Conversation content sync was disposed.'),
    );
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
    await _syncUpdatesController.close();
  }
}

class _ConversationTimelineBaseRevisionMismatch implements Exception {
  const _ConversationTimelineBaseRevisionMismatch();
}

class _ConversationSyncSequenceGap implements Exception {
  const _ConversationSyncSequenceGap({
    required this.expected,
    required this.actual,
  });

  final int expected;
  final int actual;
}

class _ConversationSyncBeginMismatch implements Exception {
  const _ConversationSyncBeginMismatch();
}

class _ConversationPagingInterrupted implements Exception {
  const _ConversationPagingInterrupted();

  @override
  String toString() => 'Conversation history paging was interrupted.';
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

class _PendingTurnsPage {
  const _PendingTurnsPage({
    required this.generation,
    required this.targetFingerprint,
    required this.provider,
    required this.providerSessionId,
    required this.completer,
  });

  final int generation;
  final String targetFingerprint;
  final String provider;
  final String providerSessionId;
  final Completer<ConversationTurnsPageLoadResult> completer;
}

class _PendingItemsPage {
  const _PendingItemsPage({
    required this.generation,
    required this.targetFingerprint,
    required this.provider,
    required this.providerSessionId,
    required this.turnId,
    required this.toolUseIds,
    required this.completer,
  });

  final int generation;
  final String targetFingerprint;
  final String provider;
  final String providerSessionId;
  final String turnId;
  final List<String> toolUseIds;
  final Completer<List<HistoryToolDetail>?> completer;
}

class _PendingLatestTurnRepairPage {
  const _PendingLatestTurnRepairPage({
    required this.generation,
    required this.targetFingerprint,
    required this.provider,
    required this.providerSessionId,
    required this.revision,
    required this.repair,
    required this.turnId,
    required this.maximumBytes,
    required this.completer,
  });

  final int generation;
  final String targetFingerprint;
  final String provider;
  final String providerSessionId;
  final String revision;
  final String repair;
  final String? turnId;
  final int maximumBytes;
  final Completer<_LatestTurnRepairPageResult> completer;
}

class _LatestTurnRepairPageResult {
  const _LatestTurnRepairPageResult({
    required this.snapshot,
    required this.pageBytes,
  });

  final ConversationHotWindowSnapshot snapshot;
  final int pageBytes;
}
