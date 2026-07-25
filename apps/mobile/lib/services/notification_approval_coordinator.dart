import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/logger.dart';
import '../models/messages.dart';
import 'bridge_service.dart';

enum NotificationApprovalDecision { approve, reject }

abstract interface class NotificationApprovalBridge {
  bool get isConnected;
  bool get hasAuthoritativeSessionListForCurrentConnection;
  List<SessionInfo> get sessions;
  Stream<List<SessionInfo>> get sessionList;
  Stream<BridgeConnectionState> get connectionStatus;

  void send(ClientMessage message);
  void markToolUseResponded(String sessionId, String toolUseId);
  void clearSessionPermission(String sessionId);
}

class BridgeServiceNotificationApprovalBridge
    implements NotificationApprovalBridge {
  const BridgeServiceNotificationApprovalBridge(this._bridge);

  final BridgeService _bridge;

  @override
  bool get isConnected => _bridge.isConnected;

  @override
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      _bridge.hasAuthoritativeSessionListForCurrentConnection;

  @override
  List<SessionInfo> get sessions => _bridge.sessions;

  @override
  Stream<List<SessionInfo>> get sessionList => _bridge.sessionList;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _bridge.connectionStatus;

  @override
  void send(ClientMessage message) => _bridge.send(message);

  @override
  void markToolUseResponded(String sessionId, String toolUseId) =>
      _bridge.markToolUseResponded(sessionId, toolUseId);

  @override
  void clearSessionPermission(String sessionId) =>
      _bridge.clearSessionPermission(sessionId);
}

class NotificationApprovalRequest {
  const NotificationApprovalRequest({
    required this.sessionId,
    required this.provider,
    required this.permissionId,
    required this.decision,
    required this.createdAt,
    this.providerSessionId,
  });

  final String sessionId;
  final String provider;
  final String? providerSessionId;
  final String permissionId;
  final NotificationApprovalDecision decision;
  final DateTime createdAt;

  String get identity =>
      '$provider:${providerSessionId ?? sessionId}:$permissionId';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'provider': provider,
    'providerSessionId': ?providerSessionId,
    'permissionId': permissionId,
    'decision': decision.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static NotificationApprovalRequest? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    final sessionId = _jsonString(json['sessionId']) ?? '';
    final provider = _jsonString(json['provider']) ?? '';
    final providerSessionId = _jsonString(json['providerSessionId']);
    final permissionId = _jsonString(json['permissionId']) ?? '';
    final createdAt = DateTime.tryParse(_jsonString(json['createdAt']) ?? '');
    final decision = switch (json['decision']) {
      'approve' => NotificationApprovalDecision.approve,
      'reject' => NotificationApprovalDecision.reject,
      _ => null,
    };
    if (createdAt == null || decision == null) {
      return null;
    }
    final request = NotificationApprovalRequest(
      sessionId: sessionId,
      provider: provider,
      providerSessionId: providerSessionId?.isNotEmpty == true
          ? providerSessionId
          : null,
      permissionId: permissionId,
      decision: decision,
      createdAt: createdAt,
    );
    return request.isValid ? request : null;
  }

  bool get isValid =>
      sessionId.isNotEmpty &&
      sessionId.length <= 256 &&
      (provider == 'claude' || provider == 'codex') &&
      permissionId.isNotEmpty &&
      permissionId.length <= 256 &&
      (providerSessionId == null || providerSessionId!.length <= 256) &&
      createdAt.isUtc;
}

String? _jsonString(Object? value) {
  if (value is! String) return null;
  return value.trim();
}

/// Revalidates notification actions against the Bridge-owned pending ledger.
///
/// Notification buttons never carry a command or approval policy. They carry
/// only an opaque permission ID, and the action is sent on the current live
/// socket only after the same pending request is present in an authoritative
/// session snapshot.
class NotificationApprovalCoordinator {
  factory NotificationApprovalCoordinator({
    required SharedPreferences preferences,
    required NotificationApprovalBridge bridge,
  }) => NotificationApprovalCoordinator._(preferences, bridge);

  NotificationApprovalCoordinator._(this._preferences, this._bridge);

  static const _preferenceKey = 'notification_approval_queue_v1';
  static const _maxPending = 8;
  static const _maxAge = Duration(minutes: 10);

  final SharedPreferences _preferences;
  final NotificationApprovalBridge _bridge;
  final List<NotificationApprovalRequest> _pending = [];
  StreamSubscription<List<SessionInfo>>? _sessionSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  Future<void> _persistChain = Future<void>.value();
  Future<void>? _disposeFuture;
  Timer? _retryTimer;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final raw = _preferences.getString(_preferenceKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final request = NotificationApprovalRequest.fromJson(item);
            if (request != null &&
                !_isExpired(request) &&
                !_isTooFarInFuture(request)) {
              _pending.removeWhere(
                (existing) => existing.identity == request.identity,
              );
              _pending.add(request);
            }
          }
          if (_pending.length > _maxPending) {
            _pending.removeRange(0, _pending.length - _maxPending);
          }
        }
      } catch (error, stackTrace) {
        logger.warning(
          '[notifications] invalid persisted approval action',
          error,
          stackTrace,
        );
      }
      await _persist();
    }
    _sessionSub = _bridge.sessionList.listen((_) => _drain());
    _connectionSub = _bridge.connectionStatus.listen((_) => _drain());
    _drain();
  }

  Future<void> submit(NotificationApprovalRequest request) async {
    if (!request.isValid || _isExpired(request) || _isTooFarInFuture(request)) {
      return;
    }
    if (!_initialized) await initialize();
    _pending.removeWhere((item) => item.identity == request.identity);
    _pending.add(request);
    if (_pending.length > _maxPending) {
      _pending.removeRange(0, _pending.length - _maxPending);
    }
    await _persist();
    _drain();
  }

  void _drain() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final beforePrune = _pending.length;
    _pending.removeWhere(
      (request) => _isExpired(request) || _isTooFarInFuture(request),
    );
    var changed = _pending.length != beforePrune;
    if (!_bridge.isConnected ||
        !_bridge.hasAuthoritativeSessionListForCurrentConnection) {
      if (changed) unawaited(_persist());
      if (_pending.isNotEmpty && _bridge.isConnected) {
        _retryTimer = Timer(const Duration(seconds: 1), _drain);
      }
      return;
    }

    var retryAfterSendFailure = false;
    for (final request in List<NotificationApprovalRequest>.of(_pending)) {
      final session = _matchingSession(request);
      if (session == null) continue;
      try {
        final message = request.decision == NotificationApprovalDecision.approve
            ? ClientMessage.approveLiveOnly(
                request.permissionId,
                sessionId: session.id,
              )
            : ClientMessage.rejectLiveOnly(
                request.permissionId,
                sessionId: session.id,
              );
        _bridge.send(message);
        _bridge.markToolUseResponded(session.id, request.permissionId);
        _bridge.clearSessionPermission(session.id);
        _pending.remove(request);
        changed = true;
      } catch (error, stackTrace) {
        logger.warning(
          '[notifications] approval action send failed',
          error,
          stackTrace,
        );
        retryAfterSendFailure = true;
      }
    }
    if (changed) unawaited(_persist());
    if (_pending.isNotEmpty && retryAfterSendFailure) {
      _retryTimer = Timer(const Duration(seconds: 1), _drain);
    }
  }

  SessionInfo? _matchingSession(NotificationApprovalRequest request) {
    final matches = _bridge.sessions
        .where((session) {
          final pending = session.pendingPermission;
          if (pending?.toolUseId != request.permissionId) return false;
          if ((session.provider ?? 'claude') != request.provider) return false;
          if (session.id == request.sessionId) return true;
          final providerSessionId = request.providerSessionId;
          return providerSessionId != null &&
              providerSessionId.isNotEmpty &&
              session.claudeSessionId == providerSessionId;
        })
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  bool _isExpired(NotificationApprovalRequest request) {
    return DateTime.now().toUtc().difference(request.createdAt.toUtc()) >
        _maxAge;
  }

  bool _isTooFarInFuture(NotificationApprovalRequest request) {
    return request.createdAt.toUtc().difference(DateTime.now().toUtc()) >
        const Duration(minutes: 1);
  }

  Future<void> _persist() async {
    final encoded = _pending.isEmpty
        ? null
        : jsonEncode(_pending.map((request) => request.toJson()).toList());
    _persistChain = _persistChain
        .then((_) async {
          if (encoded == null) {
            await _preferences.remove(_preferenceKey);
          } else {
            await _preferences.setString(_preferenceKey, encoded);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          logger.warning(
            '[notifications] approval queue persistence failed',
            error,
            stackTrace,
          );
        });
    await _persistChain;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _retryTimer?.cancel();
    await _sessionSub?.cancel();
    await _connectionSub?.cancel();
    await _persistChain;
  }
}
