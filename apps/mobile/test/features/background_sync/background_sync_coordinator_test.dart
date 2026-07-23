import 'dart:async';

import 'package:ccpocket/features/background_sync/background_sync_coordinator.dart';
import 'package:ccpocket/features/background_sync/background_sync_host.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'old IPA still performs foreground reconciliation after resume',
    () async {
      final host = _FakeHost();
      final bridge = _FakeBridge(
        sessionIds: const ['one', 'two'],
        cachedSessionIds: const {'one'},
      );
      final mirror = _FakeMirror();
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
        historyResponseTimeout: const Duration(milliseconds: 50),
        continuationTrackingWindow: Duration.zero,
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      await coordinator.handleLifecycleState(AppLifecycleState.hidden);
      await coordinator.handleLifecycleState(AppLifecycleState.paused);
      await coordinator.handleLifecycleState(AppLifecycleState.resumed);

      expect(host.beginGenerations, isEmpty);
      expect(host.scheduleCount, 0);
      expect(bridge.ensureConnectedCount, 1);
      expect(bridge.sessionListRequestCount, 1);
      expect(bridge.historyRequests, ['one', 'two']);
      expect(bridge.historyFullFallbackPermissions, [true, true]);
      expect(mirror.calls, [
        const _MirrorCall(maximumConversations: 8, restoreMissingWatches: true),
      ]);

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test('hidden and paused share one finite continuation generation', () async {
    final host = _FakeHost(
      supportsContinuation: true,
      supportsAppRefresh: true,
    );
    final bridge = _FakeBridge(
      hasBackgroundWork: true,
      sessionIds: const ['active'],
      cachedSessionIds: const {'active'},
    );
    final mirror = _FakeMirror();
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      historyResponseTimeout: const Duration(milliseconds: 50),
      continuationTrackingWindow: Duration.zero,
    )..start(initialLifecycleState: AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    await coordinator.handleLifecycleState(AppLifecycleState.hidden);
    await coordinator.handleLifecycleState(AppLifecycleState.paused);

    expect(host.beginGenerations, [1]);
    expect(host.endGenerations, [1]);
    expect(host.scheduleCount, 2);
    expect(bridge.historyRequests, ['active']);
    expect(mirror.calls.single.restoreMissingWatches, isFalse);
    expect(mirror.calls.single.maximumConversations, 2);
    expect(mirror.automaticWatchRestorationStates, [true, false]);

    await coordinator.handleLifecycleState(AppLifecycleState.resumed);
    expect(bridge.historyRequests, ['active', 'active']);
    expect(mirror.calls.last.restoreMissingWatches, isTrue);
    expect(mirror.automaticWatchRestorationStates, [true, false, true]);

    await coordinator.dispose();
    await bridge.dispose();
  });

  test('app refresh only requests bounded cached deltas', () async {
    final host = _FakeHost(supportsAppRefresh: true);
    final bridge = _FakeBridge(
      sessionIds: const ['cached', 'uncached'],
      cachedSessionIds: const {'cached'},
    );
    final mirror = _FakeMirror();
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      historyResponseTimeout: const Duration(milliseconds: 50),
    )..start(initialLifecycleState: AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    final success = await host.performRefresh('refresh-1');

    expect(success, isTrue);
    expect(bridge.historyRequests, ['cached']);
    expect(bridge.historyFullFallbackPermissions, [false]);
    expect(
      mirror.calls.single,
      const _MirrorCall(maximumConversations: 2, restoreMissingWatches: false),
    );
    expect(mirror.automaticWatchRestorationStates, [true, false, true]);
    expect(host.scheduleCount, 2);
    expect(host.markReadyCount, 1);
    expect(host.readySawRefreshHandler, isTrue);

    await coordinator.dispose();
    await bridge.dispose();
  });

  test(
    'continuation remains alive while an active turn is streaming',
    () async {
      final host = _FakeHost(supportsContinuation: true);
      final bridge = _FakeBridge(
        hasBackgroundWork: true,
        sessionIds: const ['active'],
        cachedSessionIds: const {'active'},
      );
      final mirror = _FakeMirror();
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
        historyResponseTimeout: const Duration(milliseconds: 50),
        continuationTrackingWindow: const Duration(seconds: 1),
        continuationTrackingPoll: const Duration(milliseconds: 5),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      final enteringBackground = coordinator.handleLifecycleState(
        AppLifecycleState.hidden,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(host.endGenerations, isEmpty);
      bridge.hasBackgroundWork = false;
      await enteringBackground.timeout(const Duration(milliseconds: 200));
      expect(host.endGenerations, [1]);

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test(
    'foreground rebuilds an unresponsive route before trusting sessions',
    () async {
      final host = _FakeHost();
      final bridge = _FakeBridge(
        autoRespondToSessionList: false,
        respondAfterRebuild: true,
        sessionIds: const ['after-rebuild'],
      );
      final mirror = _FakeMirror();
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
        sessionListTimeout: const Duration(milliseconds: 20),
        historyResponseTimeout: const Duration(milliseconds: 50),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      await coordinator.handleLifecycleState(AppLifecycleState.hidden);
      await coordinator.handleLifecycleState(AppLifecycleState.resumed);

      expect(bridge.rebuildCount, 1);
      expect(bridge.sessionListRequestCount, 2);
      expect(bridge.historyRequests, ['after-rebuild']);

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test('expired native refresh does not touch Bridge state', () async {
    final host = _FakeHost(supportsAppRefresh: true);
    final bridge = _FakeBridge(sessionIds: const ['active']);
    final mirror = _FakeMirror();
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      historyResponseTimeout: const Duration(milliseconds: 50),
    )..start(initialLifecycleState: AppLifecycleState.resumed);

    final request = BackgroundRefreshRequest(
      runId: 'expired',
      deadline: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final success = await host.performRequest(request);

    expect(success, isFalse);
    expect(bridge.ensureConnectedCount, 0);
    expect(bridge.sessionListRequestCount, 0);
    expect(bridge.historyRequests, isEmpty);

    await coordinator.dispose();
    await bridge.dispose();
  });

  test('native refresh expiry cancels a pending Bridge wait', () async {
    final host = _FakeHost(supportsAppRefresh: true);
    final bridge = _FakeBridge(autoRespondToSessionList: false);
    final mirror = _FakeMirror();
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      sessionListTimeout: const Duration(seconds: 5),
    )..start(initialLifecycleState: AppLifecycleState.resumed);
    final request = BackgroundRefreshRequest(
      runId: 'expires-during-wait',
      deadline: DateTime.now().add(const Duration(seconds: 30)),
    );

    final refresh = host.performRequest(request);
    await Future<void>.delayed(Duration.zero);
    request.expire();

    expect(await refresh.timeout(const Duration(milliseconds: 200)), isFalse);
    expect(bridge.hasSessionListListener, isFalse);

    await coordinator.dispose();
    await bridge.dispose();
  });

  test('native refresh expiry cancels pending resident mirror work', () async {
    final host = _FakeHost(supportsAppRefresh: true);
    final bridge = _FakeBridge(
      sessionIds: const ['active'],
      cachedSessionIds: const {'active'},
    );
    final mirror = _FakeMirror()..holdNextReconcile = true;
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      historyResponseTimeout: const Duration(milliseconds: 50),
    )..start(initialLifecycleState: AppLifecycleState.resumed);
    final request = BackgroundRefreshRequest(
      runId: 'expires-during-mirror',
      deadline: DateTime.now().add(const Duration(seconds: 30)),
    );

    final refresh = host.performRequest(request);
    await mirror.reconcileStarted.future;
    request.expire();

    expect(await refresh.timeout(const Duration(milliseconds: 200)), isFalse);
    expect(mirror.reconcileCancelled, isTrue);

    await coordinator.dispose();
    await bridge.dispose();
  });

  test(
    'foreground refresh restores resident watch recreation without lifecycle',
    () async {
      final host = _FakeHost(supportsAppRefresh: true);
      final bridge = _FakeBridge();
      final mirror = _FakeMirror();
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      expect(await host.performRefresh('warm-foreground'), isTrue);
      expect(mirror.automaticWatchRestorationStates, [true, false, true]);

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test('initial paused state stays backgrounded until first resume', () async {
    final host = _FakeHost(supportsAppRefresh: true);
    final bridge = _FakeBridge();
    final mirror = _FakeMirror();
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
    )..start(initialLifecycleState: AppLifecycleState.paused);

    expect(await host.performRefresh('initially-paused'), isTrue);
    expect(mirror.automaticWatchRestorationStates, [false, false]);

    await coordinator.handleLifecycleState(AppLifecycleState.resumed);
    expect(mirror.automaticWatchRestorationStates, [false, false, true]);

    await coordinator.dispose();
    await bridge.dispose();
  });

  test(
    'unknown startup stays fail-closed until lifecycle is definite',
    () async {
      for (final initialState in <AppLifecycleState?>[
        null,
        AppLifecycleState.detached,
        AppLifecycleState.inactive,
      ]) {
        final host = _FakeHost(supportsAppRefresh: true);
        final bridge = _FakeBridge();
        final mirror = _FakeMirror();
        final coordinator = MobileBackgroundSyncCoordinator(
          host: host,
          bridge: bridge,
          mirror: mirror,
        )..start(initialLifecycleState: initialState);
        await Future<void>.delayed(Duration.zero);

        expect(mirror.automaticWatchRestorationStates, [false]);
        expect(host.markReadyCount, 0);
        expect(host.scheduleCount, 0);

        await coordinator.handleLifecycleState(AppLifecycleState.resumed);
        expect(mirror.automaticWatchRestorationStates, [false, true]);
        expect(host.markReadyCount, 1);
        expect(host.scheduleCount, 1);

        await coordinator.dispose();
        await bridge.dispose();
      }
    },
  );

  test(
    'a stale Dart-ready result cannot schedule refresh for an unknown state',
    () async {
      final host = _FakeHost(supportsAppRefresh: true)
        ..holdNextMarkReady = true;
      final bridge = _FakeBridge();
      final mirror = _FakeMirror();
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      await host.markReadyStarted.future;
      await coordinator.handleLifecycleState(AppLifecycleState.inactive);
      host.releaseMarkReady();
      await Future<void>.delayed(Duration.zero);

      expect(host.markReadyCount, 1);
      expect(host.scheduleCount, 0);
      expect(mirror.automaticWatchRestorationStates, [true, false]);

      await coordinator.handleLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(host.markReadyCount, 1);
      expect(host.scheduleCount, 1);
      expect(mirror.automaticWatchRestorationStates, [true, false, true]);

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test(
    'rapid background transitions fence stale foreground reconciliation',
    () async {
      final host = _FakeHost(
        supportsContinuation: true,
        supportsAppRefresh: true,
      );
      final bridge = _FakeBridge(
        hasBackgroundWork: true,
        sessionIds: const ['active'],
        cachedSessionIds: const {'active'},
      );
      final mirror = _FakeMirror()..holdNextEnableRestoration = true;
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
        historyResponseTimeout: const Duration(milliseconds: 50),
        continuationTrackingWindow: const Duration(seconds: 1),
        continuationTrackingPoll: const Duration(milliseconds: 5),
      )..start(initialLifecycleState: AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      final firstBackground = coordinator.handleLifecycleState(
        AppLifecycleState.hidden,
      );
      await _waitUntil(() => host.beginGenerations.contains(1));

      final staleResume = coordinator.handleLifecycleState(
        AppLifecycleState.resumed,
      );
      await mirror.enableRestorationStarted.future;
      expect(
        host.endGenerations.where((generation) => generation == 1),
        hasLength(1),
      );

      final secondBackground = coordinator.handleLifecycleState(
        AppLifecycleState.hidden,
      );
      await _waitUntil(() => host.beginGenerations.contains(2));
      mirror.releaseEnableRestoration();
      await staleResume.timeout(const Duration(milliseconds: 200));

      expect(bridge.historyFullFallbackPermissions, isNotEmpty);
      expect(bridge.historyFullFallbackPermissions, everyElement(isFalse));
      expect(mirror.calls, isNotEmpty);
      expect(
        mirror.calls.map((call) => call.restoreMissingWatches),
        everyElement(isFalse),
      );
      expect(coordinator.activeContinuationGeneration, 2);

      bridge.hasBackgroundWork = false;
      await Future.wait([
        firstBackground,
        secondBackground,
      ]).timeout(const Duration(milliseconds: 300));
      expect(
        host.endGenerations.where((generation) => generation == 1),
        hasLength(1),
      );
      expect(
        host.endGenerations.where((generation) => generation == 2),
        hasLength(1),
      );

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test(
    'an interrupted resume preserves the pending foreground catch-up',
    () async {
      final host = _FakeHost();
      final bridge = _FakeBridge(
        sessionIds: const ['active'],
        cachedSessionIds: const {'active'},
      );
      final mirror = _FakeMirror()..holdNextEnableRestoration = true;
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
        historyResponseTimeout: const Duration(milliseconds: 50),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      await coordinator.handleLifecycleState(AppLifecycleState.hidden);
      final interruptedResume = coordinator.handleLifecycleState(
        AppLifecycleState.resumed,
      );
      await mirror.enableRestorationStarted.future;
      await coordinator.handleLifecycleState(AppLifecycleState.inactive);
      mirror.releaseEnableRestoration();
      await interruptedResume.timeout(const Duration(milliseconds: 200));

      expect(bridge.historyRequests, isEmpty);
      await coordinator.handleLifecycleState(AppLifecycleState.resumed);
      expect(bridge.historyRequests, ['active']);
      expect(bridge.historyFullFallbackPermissions, [true]);

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test(
    'history reconciliation waits for the correlated Bridge response',
    () async {
      final host = _FakeHost(supportsAppRefresh: true);
      final bridge = _FakeBridge(
        sessionIds: const ['active'],
        cachedSessionIds: const {'active'},
        autoRespondToHistory: false,
      );
      final mirror = _FakeMirror();
      final coordinator = MobileBackgroundSyncCoordinator(
        host: host,
        bridge: bridge,
        mirror: mirror,
        historyResponseTimeout: const Duration(milliseconds: 200),
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      var completed = false;
      final refresh = host.performRefresh('slow-history').then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);

      expect(bridge.historyRequests, ['active']);
      expect(completed, isFalse);
      bridge.emitRawHistoryReconciliation('active');
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      bridge.emitHistoryReconciliation('active');
      expect(await refresh, isTrue);

      await coordinator.dispose();
      await bridge.dispose();
    },
  );

  test('machine identity parser accepts only canonical machine identities', () {
    expect(
      machineIdFromLogicalConnectionIdentity('machine:device-1'),
      'device-1',
    );
    expect(
      machineIdFromLogicalConnectionIdentity('  machine:device-2  '),
      'device-2',
    );
    expect(machineIdFromLogicalConnectionIdentity('machine:'), isNull);
    expect(
      machineIdFromLogicalConnectionIdentity('ws://127.0.0.1:8765'),
      isNull,
    );
    expect(machineIdFromLogicalConnectionIdentity(null), isNull);
  });

  test('a failed mirror run does not poison the serial sync tail', () async {
    final host = _FakeHost(supportsAppRefresh: true);
    final bridge = _FakeBridge(
      sessionIds: const ['active'],
      cachedSessionIds: const {'active'},
    );
    final mirror = _FakeMirror()..throwOnNextReconcile = true;
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      historyResponseTimeout: const Duration(milliseconds: 50),
    )..start(initialLifecycleState: AppLifecycleState.resumed);

    expect(await host.performRefresh('throws'), isFalse);
    expect(await host.performRefresh('recovers'), isTrue);
    expect(mirror.calls, hasLength(2));

    await coordinator.dispose();
    await bridge.dispose();
  });

  test('continuation expiration cancels the pending Bridge wait', () async {
    final host = _FakeHost(supportsContinuation: true);
    final bridge = _FakeBridge(
      hasBackgroundWork: true,
      autoRespondToSessionList: false,
      sessionIds: const ['active'],
    );
    final mirror = _FakeMirror();
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      sessionListTimeout: const Duration(seconds: 5),
    )..start(initialLifecycleState: AppLifecycleState.resumed);

    final enteringBackground = coordinator.handleLifecycleState(
      AppLifecycleState.hidden,
    );
    await Future<void>.delayed(Duration.zero);
    host.expireContinuation(1);
    await enteringBackground.timeout(const Duration(milliseconds: 200));

    expect(host.endGenerations, [1]);
    expect(bridge.hasSessionListListener, isFalse);

    await coordinator.dispose();
    await bridge.dispose();
  });

  test('timed out stream waits release their subscriptions', () async {
    final host = _FakeHost(supportsAppRefresh: true);
    final bridge = _FakeBridge(autoRespondToSessionList: false);
    final mirror = _FakeMirror();
    final coordinator = MobileBackgroundSyncCoordinator(
      host: host,
      bridge: bridge,
      mirror: mirror,
      sessionListTimeout: const Duration(milliseconds: 5),
    )..start(initialLifecycleState: AppLifecycleState.resumed);

    expect(await host.performRefresh('timeout'), isFalse);
    expect(bridge.hasSessionListListener, isFalse);
    expect(bridge.hasConnectionListener, isFalse);

    await coordinator.dispose();
    await bridge.dispose();
  });
}

class _FakeHost implements BackgroundSyncHost {
  _FakeHost({
    this.supportsContinuation = false,
    this.supportsAppRefresh = false,
  });

  @override
  final bool supportsContinuation;
  @override
  final bool supportsAppRefresh;

  BackgroundRefreshHandler? handler;
  BackgroundContinuationExpirationHandler? continuationExpirationHandler;
  final List<int> beginGenerations = [];
  final List<int> endGenerations = [];
  int scheduleCount = 0;
  int markReadyCount = 0;
  bool readySawRefreshHandler = false;
  bool holdNextMarkReady = false;
  final Completer<void> markReadyStarted = Completer<void>();
  Completer<void>? _markReadyRelease;

  @override
  void setRefreshHandler(BackgroundRefreshHandler? handler) {
    this.handler = handler;
  }

  @override
  void setContinuationExpirationHandler(
    BackgroundContinuationExpirationHandler? handler,
  ) {
    continuationExpirationHandler = handler;
  }

  @override
  Future<bool> markDartReady() async {
    markReadyCount++;
    readySawRefreshHandler = handler != null;
    if (holdNextMarkReady) {
      holdNextMarkReady = false;
      _markReadyRelease = Completer<void>();
      if (!markReadyStarted.isCompleted) {
        markReadyStarted.complete();
      }
      await _markReadyRelease!.future;
    }
    return supportsAppRefresh;
  }

  void releaseMarkReady() {
    final release = _markReadyRelease;
    if (release != null && !release.isCompleted) {
      release.complete();
    }
  }

  @override
  Future<bool> beginContinuation({
    required int generation,
    required String reason,
  }) async {
    beginGenerations.add(generation);
    return true;
  }

  @override
  Future<void> endContinuation({required int generation}) async {
    endGenerations.add(generation);
  }

  @override
  Future<bool> scheduleRefresh({
    Duration earliestBegin = backgroundSyncMinimumRefreshDelay,
  }) async {
    scheduleCount++;
    return true;
  }

  Future<bool> performRefresh(String runId) => performRequest(
    BackgroundRefreshRequest(
      runId: runId,
      deadline: DateTime.now().add(const Duration(seconds: 30)),
    ),
  );

  Future<bool> performRequest(BackgroundRefreshRequest request) async {
    final callback = handler;
    return callback == null ? false : callback(request);
  }

  void expireContinuation(int generation) {
    continuationExpirationHandler?.call(generation);
  }

  @override
  Future<void> dispose() async {
    handler = null;
    continuationExpirationHandler = null;
  }
}

class _FakeBridge implements BackgroundSyncBridgeGateway {
  _FakeBridge({
    this.hasBackgroundWork = false,
    this.autoRespondToSessionList = true,
    this.respondAfterRebuild = false,
    this.autoRespondToHistory = true,
    List<String> sessionIds = const [],
    Set<String> cachedSessionIds = const {},
  }) : activeSessionIds = List.of(sessionIds),
       _cachedSessionIds = Set.of(cachedSessionIds);

  final _connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final _sessionController = StreamController<void>.broadcast();
  final _historyController = StreamController<String>.broadcast();
  final Set<String> _cachedSessionIds;

  @override
  bool isConnected = true;
  @override
  bool hasAuthoritativeSessionList = true;
  @override
  int authoritativeSessionListGeneration = 0;
  @override
  bool hasBackgroundWork;
  @override
  final List<String> activeSessionIds;
  bool autoRespondToSessionList;
  final bool respondAfterRebuild;
  final bool autoRespondToHistory;
  int ensureConnectedCount = 0;
  int rebuildCount = 0;
  int sessionListRequestCount = 0;
  final List<String> historyRequests = [];
  final List<bool> historyFullFallbackPermissions = [];
  final Map<String, int> _historyReconciliationGenerations = {};
  bool get hasConnectionListener => _connectionController.hasListener;
  bool get hasSessionListListener => _sessionController.hasListener;

  @override
  Stream<BridgeConnectionState> get connectionStates =>
      _connectionController.stream;
  @override
  Stream<void> get sessionListChanges => _sessionController.stream;
  @override
  Stream<String> get sessionHistoryReconciliations => _historyController.stream;

  @override
  int sessionHistoryReconciliationGeneration(String sessionId) =>
      _historyReconciliationGenerations[sessionId] ?? 0;

  @override
  void ensureConnected() {
    ensureConnectedCount++;
    if (!isConnected) {
      isConnected = true;
      _connectionController.add(BridgeConnectionState.connected);
    }
  }

  @override
  Future<bool> rebuildConnection() async {
    rebuildCount++;
    if (!respondAfterRebuild) return false;
    isConnected = true;
    hasAuthoritativeSessionList = false;
    autoRespondToSessionList = true;
    _connectionController.add(BridgeConnectionState.connected);
    return true;
  }

  @override
  void requestSessionList() {
    sessionListRequestCount++;
    if (!autoRespondToSessionList) return;
    authoritativeSessionListGeneration++;
    hasAuthoritativeSessionList = true;
    _sessionController.add(null);
  }

  @override
  void requestSessionHistory(
    String sessionId, {
    required bool allowFullFallback,
  }) {
    historyRequests.add(sessionId);
    historyFullFallbackPermissions.add(allowFullFallback);
    if (autoRespondToHistory) {
      emitHistoryReconciliation(sessionId);
    }
  }

  void emitHistoryReconciliation(String sessionId) {
    _historyReconciliationGenerations[sessionId] =
        sessionHistoryReconciliationGeneration(sessionId) + 1;
    _historyController.add(sessionId);
  }

  void emitRawHistoryReconciliation(String sessionId) {
    _historyController.add(sessionId);
  }

  @override
  bool hasCachedSessionHistory(String sessionId) =>
      _cachedSessionIds.contains(sessionId);

  Future<void> dispose() async {
    await _connectionController.close();
    await _sessionController.close();
    await _historyController.close();
  }
}

class _FakeMirror implements BackgroundSyncMirrorGateway {
  final List<_MirrorCall> calls = [];
  final List<bool> automaticWatchRestorationStates = [];
  bool throwOnNextReconcile = false;
  bool holdNextReconcile = false;
  bool holdNextEnableRestoration = false;
  bool reconcileCancelled = false;
  final Completer<void> reconcileStarted = Completer<void>();
  final Completer<void> enableRestorationStarted = Completer<void>();
  final Completer<void> _enableRestorationGate = Completer<void>();

  @override
  Future<void> setAutomaticWatchRestorationEnabled(bool enabled) async {
    automaticWatchRestorationStates.add(enabled);
    if (enabled && holdNextEnableRestoration) {
      holdNextEnableRestoration = false;
      if (!enableRestorationStarted.isCompleted) {
        enableRestorationStarted.complete();
      }
      await _enableRestorationGate.future;
    }
  }

  void releaseEnableRestoration() {
    if (!_enableRestorationGate.isCompleted) {
      _enableRestorationGate.complete();
    }
  }

  @override
  Future<void> reconcileResidents({
    required int maximumConversations,
    required Duration budget,
    required bool restoreMissingWatches,
    ConversationMirrorCancellation? cancellation,
  }) async {
    calls.add(
      _MirrorCall(
        maximumConversations: maximumConversations,
        restoreMissingWatches: restoreMissingWatches,
      ),
    );
    if (throwOnNextReconcile) {
      throwOnNextReconcile = false;
      throw StateError('mirror failed');
    }
    if (holdNextReconcile) {
      holdNextReconcile = false;
      if (!reconcileStarted.isCompleted) reconcileStarted.complete();
      final cancelled = Completer<void>();
      void cancel() {
        reconcileCancelled = true;
        if (!cancelled.isCompleted) cancelled.complete();
      }

      cancellation?.addListener(cancel);
      try {
        if (cancellation?.isCancelled == true) cancel();
        await cancelled.future;
      } finally {
        cancellation?.removeListener(cancel);
      }
    }
  }
}

class _MirrorCall {
  const _MirrorCall({
    required this.maximumConversations,
    required this.restoreMissingWatches,
  });

  final int maximumConversations;
  final bool restoreMissingWatches;

  @override
  bool operator ==(Object other) =>
      other is _MirrorCall &&
      other.maximumConversations == maximumConversations &&
      other.restoreMissingWatches == restoreMissingWatches;

  @override
  int get hashCode => Object.hash(maximumConversations, restoreMissingWatches);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition did not become true before the test deadline.');
}
