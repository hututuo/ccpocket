import 'dart:async';

import 'package:flutter/services.dart';

// Public constructor labels intentionally describe injectable collaborators;
// initializing formals would expose private field names to callers.
// ignore_for_file: prefer_initializing_formals

const backgroundSyncHostChannelName = 'ccpocket/background_sync';
const backgroundSyncHostCallTimeout = Duration(seconds: 2);
const backgroundSyncMinimumRefreshDelay = Duration(minutes: 15);

typedef BackgroundRefreshHandler =
    Future<bool> Function(BackgroundRefreshRequest request);
typedef BackgroundContinuationExpirationHandler = void Function(int generation);

class BackgroundRefreshRequest {
  BackgroundRefreshRequest({required this.runId, required this.deadline});

  final String runId;
  final DateTime deadline;
  bool _expired = false;
  final Set<void Function()> _expirationListeners = {};

  bool get isExpired => _expired || !DateTime.now().isBefore(deadline);

  Duration get remaining {
    final value = deadline.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  void expire() {
    if (_expired) return;
    _expired = true;
    final listeners = List<void Function()>.from(_expirationListeners);
    _expirationListeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void addExpirationListener(void Function() listener) {
    if (isExpired) {
      listener();
      return;
    }
    _expirationListeners.add(listener);
  }

  void removeExpirationListener(void Function() listener) {
    _expirationListeners.remove(listener);
  }
}

abstract interface class BackgroundSyncHost {
  bool get supportsContinuation;
  bool get supportsAppRefresh;

  void setRefreshHandler(BackgroundRefreshHandler? handler);
  void setContinuationExpirationHandler(
    BackgroundContinuationExpirationHandler? handler,
  );

  /// Announces that the Dart callback handler is installed.
  ///
  /// iOS can create the native method channel before [main] has installed its
  /// Dart handler. A delivered refresh task must remain pending until this
  /// handshake succeeds instead of being failed as `notImplemented`.
  Future<bool> markDartReady();

  Future<bool> beginContinuation({
    required int generation,
    required String reason,
  });

  Future<void> endContinuation({required int generation});

  Future<bool> scheduleRefresh({
    Duration earliestBegin = backgroundSyncMinimumRefreshDelay,
  });

  Future<void> dispose();
}

class MethodChannelBackgroundSyncHost implements BackgroundSyncHost {
  MethodChannelBackgroundSyncHost({
    required this.supportsContinuation,
    required this.supportsAppRefresh,
    MethodChannel channel = const MethodChannel(backgroundSyncHostChannelName),
  }) : _channel = channel {
    if (supportsAppRefresh || supportsContinuation) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  @override
  final bool supportsContinuation;
  @override
  final bool supportsAppRefresh;

  final MethodChannel _channel;
  final Map<String, _RefreshInvocation> _refreshInvocations = {};
  final Map<String, bool> _completedRefreshes = {};
  BackgroundRefreshHandler? _refreshHandler;
  BackgroundContinuationExpirationHandler? _continuationExpirationHandler;
  bool _disposed = false;

  @override
  void setRefreshHandler(BackgroundRefreshHandler? handler) {
    if (_disposed) return;
    _refreshHandler = handler;
  }

  @override
  void setContinuationExpirationHandler(
    BackgroundContinuationExpirationHandler? handler,
  ) {
    if (_disposed) return;
    _continuationExpirationHandler = handler;
  }

  @override
  Future<bool> markDartReady() async {
    if (_disposed || !supportsAppRefresh) return false;
    return _invokeAccepted('setDartReady');
  }

  @override
  Future<bool> beginContinuation({
    required int generation,
    required String reason,
  }) async {
    if (_disposed || !supportsContinuation) return false;
    return _invokeAccepted('beginContinuation', {
      'generation': generation,
      'reason': reason,
    });
  }

  @override
  Future<void> endContinuation({required int generation}) async {
    if (_disposed || !supportsContinuation) return;
    await _invokeAccepted('endContinuation', {'generation': generation});
  }

  @override
  Future<bool> scheduleRefresh({
    Duration earliestBegin = backgroundSyncMinimumRefreshDelay,
  }) async {
    if (_disposed || !supportsAppRefresh) return false;
    final boundedDelay = earliestBegin < backgroundSyncMinimumRefreshDelay
        ? backgroundSyncMinimumRefreshDelay
        : earliestBegin;
    return _invokeAccepted('scheduleRefresh', {
      'earliestBeginSeconds': boundedDelay.inSeconds,
    });
  }

  Future<bool> _invokeAccepted(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final value = await _channel
          .invokeMethod<Object?>(method, arguments)
          .timeout(backgroundSyncHostCallTimeout);
      if (value is bool) return value;
      if (value is Map) return value['accepted'] == true;
      return false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (_disposed) return false;
    switch (call.method) {
      case 'performRefresh':
        final arguments = call.arguments;
        if (arguments is! Map) return false;
        final runId = arguments['runId'];
        final deadlineEpochMs = arguments['deadlineEpochMs'];
        if (runId is! String ||
            runId.isEmpty ||
            runId.length > 128 ||
            deadlineEpochMs is! int) {
          return false;
        }
        final completed = _completedRefreshes[runId];
        if (completed != null) return completed;
        final existing = _refreshInvocations[runId];
        if (existing != null) return existing.future;
        final request = BackgroundRefreshRequest(
          runId: runId,
          deadline: DateTime.fromMillisecondsSinceEpoch(deadlineEpochMs),
        );
        final invocation = _RefreshInvocation(request);
        _refreshInvocations[runId] = invocation;
        invocation.complete(_runRefresh(invocation));
        return invocation.future;
      case 'expireRefresh':
        final arguments = call.arguments;
        if (arguments is! Map) return false;
        final runId = arguments['runId'];
        if (runId is! String || runId.isEmpty) return false;
        _refreshInvocations[runId]?.request.expire();
        return true;
      case 'continuationExpired':
        final arguments = call.arguments;
        if (arguments is! Map) return false;
        final generation = arguments['generation'];
        if (generation is! int || generation <= 0) return false;
        _continuationExpirationHandler?.call(generation);
        return true;
      default:
        throw MissingPluginException(
          'Unknown background sync host callback: ${call.method}',
        );
    }
  }

  Future<bool> _runRefresh(_RefreshInvocation invocation) async {
    var success = false;
    try {
      final handler = _refreshHandler;
      if (handler != null && !invocation.request.isExpired) {
        success = await handler(invocation.request);
      }
    } catch (_) {
      success = false;
    } finally {
      if (invocation.request.isExpired) success = false;
      _refreshInvocations.remove(invocation.request.runId);
      _rememberCompleted(invocation.request.runId, success);
    }
    return success;
  }

  void _rememberCompleted(String runId, bool success) {
    _completedRefreshes[runId] = success;
    while (_completedRefreshes.length > 32) {
      _completedRefreshes.remove(_completedRefreshes.keys.first);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _refreshHandler = null;
    _continuationExpirationHandler = null;
    for (final invocation in _refreshInvocations.values) {
      invocation.request.expire();
    }
    _refreshInvocations.clear();
    _completedRefreshes.clear();
    if (supportsAppRefresh || supportsContinuation) {
      _channel.setMethodCallHandler(null);
    }
  }
}

class UnsupportedBackgroundSyncHost implements BackgroundSyncHost {
  const UnsupportedBackgroundSyncHost();

  @override
  bool get supportsContinuation => false;
  @override
  bool get supportsAppRefresh => false;

  @override
  void setRefreshHandler(BackgroundRefreshHandler? handler) {}

  @override
  void setContinuationExpirationHandler(
    BackgroundContinuationExpirationHandler? handler,
  ) {}

  @override
  Future<bool> markDartReady() async => false;

  @override
  Future<bool> beginContinuation({
    required int generation,
    required String reason,
  }) async => false;

  @override
  Future<void> endContinuation({required int generation}) async {}

  @override
  Future<bool> scheduleRefresh({
    Duration earliestBegin = backgroundSyncMinimumRefreshDelay,
  }) async => false;

  @override
  Future<void> dispose() async {}
}

class _RefreshInvocation {
  _RefreshInvocation(this.request);

  final BackgroundRefreshRequest request;
  final Completer<bool> _completer = Completer<bool>();

  Future<bool> get future => _completer.future;

  void complete(Future<bool> operation) {
    operation.then(
      (value) {
        if (!_completer.isCompleted) _completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_completer.isCompleted) _completer.complete(false);
      },
    );
  }
}
