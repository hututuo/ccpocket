// Public named constructor arguments cannot expose library-private field names.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logger.dart';
import '../../models/messages.dart';
import '../../services/bridge_service.dart';

/// Mobile control surface for Bridge-owned Codex automatic approval.
///
/// Mobile never answers a permission request. It only changes durable state on
/// the computer, so supervision can continue while the phone is disconnected.
class AutoApprovalService extends ChangeNotifier {
  /// Legacy Mobile-owned allowlist, retained only for one-time Bridge import.
  static const preferencesKey = 'local_feature.codex_auto_approval.enabled.v1';
  static const _pendingDisableKey =
      'local_feature.codex_auto_approval.disable_on_reconnect.v1';
  static const _bridgeScopedSessionId = 'bridge-auto-approval';

  AutoApprovalService({
    required BridgeService bridge,
    required SharedPreferences preferences,
    Duration requestTimeout = const Duration(seconds: 20),
  }) : _bridge = bridge,
       _preferences = preferences,
       _requestTimeout = requestTimeout,
       _legacyIdentityKeys = {...?preferences.getStringList(preferencesKey)},
       _globalDisablePending = preferences.getBool(_pendingDisableKey) ?? false;

  final BridgeService _bridge;
  final SharedPreferences _preferences;
  final Duration _requestTimeout;
  final Set<String> _legacyIdentityKeys;
  final Map<String, bool> _enabledByProviderSessionId = {};
  final Map<String, int> _approvedCountsByProviderSessionId = {};
  final Map<String, bool> _supportByRuntimeSessionId = {};
  final Map<String, _SettingIntent> _settingIntents = {};
  final Map<String, _PendingRequest> _pendingRequests = {};
  final Map<String, int> _queriedGenerationByProviderSessionId = {};

  StreamSubscription<List<SessionInfo>>? _sessionsSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  StreamSubscription<LocalFeatureServerMessage>? _featureSubscription;
  bool _initialized = false;
  bool _closed = false;
  bool _globalDisablePending;
  bool _legacyImportInFlight = false;
  bool _lastDisableWasQueued = false;
  int _authoritativeEnabledCount = 0;
  int _connectionGeneration = 0;
  int _requestSequence = 0;

  void initialize() {
    if (_initialized || _closed) return;
    _initialized = true;
    _sessionsSubscription = _bridge.sessionList.listen(_handleSessions);
    _connectionSubscription = _bridge.connectionStatus.listen(
      _handleConnection,
    );
    _featureSubscription = _bridge.localFeatureMessages.listen(
      _handleFeatureMessage,
    );
    if (_bridge.isConnected) {
      _connectionGeneration = 1;
      _requestBridgeState();
    }
    _handleSessions(_bridge.sessions);
  }

  bool canConfigureSession(String runtimeSessionId) {
    final target = _targetForRuntime(runtimeSessionId);
    return target != null &&
        _bridge.isConnected &&
        _supportByRuntimeSessionId[runtimeSessionId] != false;
  }

  bool isEnabledForSession(String runtimeSessionId) {
    final target = _targetForRuntime(runtimeSessionId);
    if (target == null) return false;
    return _settingIntents[target.providerSessionId]?.enabled ??
        (!_globalDisablePending &&
            (_enabledByProviderSessionId[target.providerSessionId] ?? false));
  }

  int approvedCountForSession(String runtimeSessionId) {
    final target = _targetForRuntime(runtimeSessionId);
    return target == null
        ? 0
        : (_approvedCountsByProviderSessionId[target.providerSessionId] ?? 0);
  }

  int get enabledConversationCount {
    if (_globalDisablePending) return 0;
    var count = _authoritativeEnabledCount;
    for (final entry in _settingIntents.entries) {
      final wasEnabled = _enabledByProviderSessionId[entry.key] ?? false;
      if (entry.value.enabled && !wasEnabled) count += 1;
      if (!entry.value.enabled && wasEnabled) count -= 1;
    }
    if (count == 0 && !_bridge.isConnected) {
      count = _legacyIdentityKeys.length;
    }
    return count.clamp(0, 4096);
  }

  bool get hasEnabledConversations => enabledConversationCount > 0;

  bool get lastDisableWasQueued => _lastDisableWasQueued;

  bool get isEmergencyStopPending => _globalDisablePending;

  Future<bool> setEnabledForSession(String runtimeSessionId, bool enabled) {
    final target = _targetForRuntime(runtimeSessionId);
    if (target == null || !canConfigureSession(runtimeSessionId) || _closed) {
      return Future<bool>.value(false);
    }
    if (isEnabledForSession(runtimeSessionId) == enabled) {
      return Future<bool>.value(true);
    }

    final requestId = _nextRequestId('set');
    final intent = _SettingIntent(requestId: requestId, enabled: enabled);
    _settingIntents[target.providerSessionId] = intent;
    notifyListeners();
    final completer = Completer<bool>();
    final pending = _PendingRequest(
      requestId: requestId,
      kind: _PendingRequestKind.set,
      runtimeSessionId: runtimeSessionId,
      providerSessionId: target.providerSessionId,
      completer: completer,
      timer: _requestTimer(requestId),
    );
    if (!_sendRequest(
      requestSetAutoApproval(
        sessionId: runtimeSessionId,
        requestId: requestId,
        enabled: enabled,
      ),
      pending,
    )) {
      _finishSettingIntent(target.providerSessionId, requestId);
      return Future<bool>.value(false);
    }
    return completer.future;
  }

  /// Disable Bridge-owned state now, or queue the emergency stop until the
  /// computer reconnects. Legacy Mobile state is cleared immediately.
  Future<bool> disableAll() async {
    if (_closed) return false;
    _lastDisableWasQueued = !_bridge.isConnected;
    _globalDisablePending = true;
    _settingIntents.clear();
    _legacyIdentityKeys.clear();
    await _preferences.setStringList(preferencesKey, const []);
    await _preferences.setBool(_pendingDisableKey, true);
    notifyListeners();
    if (!_bridge.isConnected) return true;
    return _sendDisableAll();
  }

  void _handleConnection(BridgeConnectionState state) {
    if (_closed) return;
    if (state == BridgeConnectionState.connected) {
      _connectionGeneration += 1;
      _supportByRuntimeSessionId.clear();
      _queriedGenerationByProviderSessionId.clear();
      _requestBridgeState();
      _handleSessions(_bridge.sessions);
      _bridge.requestSessionList();
    } else {
      _failPendingRequests();
      _legacyImportInFlight = false;
    }
    notifyListeners();
  }

  void _requestBridgeState() {
    if (!_bridge.isConnected || _closed) return;
    if (_globalDisablePending) {
      unawaited(_sendDisableAll());
      return;
    }
    _tryImportLegacyState();
  }

  void _handleSessions(List<SessionInfo> sessions) {
    if (_closed || !_bridge.isConnected) {
      notifyListeners();
      return;
    }
    _tryImportLegacyState();
    for (final session in sessions) {
      final target = _targetForSession(session);
      if (target == null ||
          _queriedGenerationByProviderSessionId[target.providerSessionId] ==
              _connectionGeneration) {
        continue;
      }
      _queriedGenerationByProviderSessionId[target.providerSessionId] =
          _connectionGeneration;
      final requestId = _nextRequestId('get');
      final pending = _PendingRequest(
        requestId: requestId,
        kind: _PendingRequestKind.query,
        runtimeSessionId: session.id,
        providerSessionId: target.providerSessionId,
        timer: _requestTimer(requestId),
      );
      if (!_sendRequest(
        requestAutoApprovalState(sessionId: session.id, requestId: requestId),
        pending,
      )) {
        _queriedGenerationByProviderSessionId.remove(target.providerSessionId);
      }
    }
    notifyListeners();
  }

  void _handleFeatureMessage(LocalFeatureServerMessage message) {
    if (_closed || message.featureId != 'auto_approval') return;
    if (message is LocalFeatureRequestErrorMessage) {
      final pending = message.requestId == null
          ? null
          : _pendingRequests.remove(message.requestId);
      pending?.timer.cancel();
      if (pending?.runtimeSessionId != null) {
        _supportByRuntimeSessionId[pending!.runtimeSessionId!] = false;
      } else {
        for (final session in _bridge.sessions) {
          if (_targetForSession(session) != null) {
            _supportByRuntimeSessionId[session.id] = false;
          }
        }
      }
      _completePendingFailure(pending);
      notifyListeners();
      return;
    }
    if (message is! AutoApprovalStateMessage) return;

    final pending = message.requestId == null
        ? null
        : _pendingRequests.remove(message.requestId);
    pending?.timer.cancel();
    final runtimeSessionId = pending?.runtimeSessionId ?? message.sessionId;
    if (runtimeSessionId != _bridgeScopedSessionId) {
      _supportByRuntimeSessionId[runtimeSessionId] = true;
    }
    if (message.isSuccess) {
      _authoritativeEnabledCount = message.enabledConversationCount;
      if (message.reason == 'disabled_all') {
        _enabledByProviderSessionId.clear();
        _globalDisablePending = false;
        _lastDisableWasQueued = false;
        _completeOtherDisableRequests(excluding: pending?.requestId);
        unawaited(_preferences.remove(_pendingDisableKey));
      }
      final providerSessionId = message.providerSessionId;
      if (providerSessionId != null && message.enabled != null) {
        _enabledByProviderSessionId[providerSessionId] = message.enabled!;
      }
      if (providerSessionId != null && message.approvedCount != null) {
        _approvedCountsByProviderSessionId[providerSessionId] =
            message.approvedCount!;
      }
      if (pending?.kind == _PendingRequestKind.set &&
          pending?.providerSessionId != null) {
        _finishSettingIntent(pending!.providerSessionId!, pending.requestId);
      }
      if (pending?.kind == _PendingRequestKind.disableAll) {
        _globalDisablePending = false;
      }
      if (pending?.kind == _PendingRequestKind.legacyImport) {
        _legacyImportInFlight = false;
        unawaited(_clearImportedLegacyKeys());
      }
      pending?.completer?.complete(true);
      if (message.reason == 'legacy_imported') {
        _queriedGenerationByProviderSessionId.clear();
        _handleSessions(_bridge.sessions);
      }
    } else {
      if (message.errorCode == 'unsupported_session' &&
          pending?.runtimeSessionId != null) {
        _supportByRuntimeSessionId[pending!.runtimeSessionId!] = false;
      }
      _completePendingFailure(pending);
    }
    notifyListeners();
  }

  void _tryImportLegacyState() {
    if (_legacyImportInFlight ||
        _legacyIdentityKeys.isEmpty ||
        !_bridge.isConnected ||
        _closed) {
      return;
    }
    final bridgeIdentity = _currentBridgeIdentity();
    if (bridgeIdentity == null) return;
    final providerSessionIds = _legacyIdentityKeys
        .map(_LegacyIdentity.tryParse)
        .whereType<_LegacyIdentity>()
        .where(
          (identity) =>
              identity.bridgeIdentity == bridgeIdentity &&
              identity.provider == Provider.codex.value,
        )
        .map((identity) => identity.providerSessionId)
        .toSet()
        .take(512)
        .toList();
    if (providerSessionIds.isEmpty) return;

    _legacyImportInFlight = true;
    final requestId = _nextRequestId('import');
    final pending = _PendingRequest(
      requestId: requestId,
      kind: _PendingRequestKind.legacyImport,
      timer: _requestTimer(requestId),
    );
    if (!_sendRequest(
      requestImportLegacyAutoApprovals(
        sessionId: _bridgeScopedSessionId,
        requestId: requestId,
        providerSessionIds: providerSessionIds,
      ),
      pending,
    )) {
      _legacyImportInFlight = false;
    }
  }

  Future<bool> _sendDisableAll() {
    final existing = _pendingRequests.values
        .where((pending) => pending.kind == _PendingRequestKind.disableAll)
        .firstOrNull;
    if (existing?.completer != null) return existing!.completer!.future;
    final requestId = _nextRequestId('disable');
    final completer = Completer<bool>();
    final pending = _PendingRequest(
      requestId: requestId,
      kind: _PendingRequestKind.disableAll,
      completer: completer,
      timer: _requestTimer(requestId),
    );
    if (!_sendRequest(
      requestDisableAllAutoApprovals(
        sessionId: _bridgeScopedSessionId,
        requestId: requestId,
      ),
      pending,
    )) {
      return completer.future;
    }
    return completer.future;
  }

  bool _sendRequest(ClientMessage message, _PendingRequest pending) {
    if (!_bridge.isConnected || _closed) {
      pending.timer.cancel();
      _completePendingFailure(pending);
      return false;
    }
    _pendingRequests[pending.requestId] = pending;
    try {
      _bridge.send(message);
      return true;
    } catch (error, stackTrace) {
      _pendingRequests.remove(pending.requestId);
      pending.timer.cancel();
      _completePendingFailure(pending);
      logger.warning(
        '[auto-approval] Failed to send Bridge setting request',
        error,
        stackTrace,
      );
      return false;
    }
  }

  Timer _requestTimer(String requestId) => Timer(_requestTimeout, () {
    final pending = _pendingRequests.remove(requestId);
    if (pending == null || _closed) return;
    if (pending.kind == _PendingRequestKind.query &&
        pending.runtimeSessionId != null) {
      _supportByRuntimeSessionId[pending.runtimeSessionId!] = false;
    }
    _completePendingFailure(pending);
    notifyListeners();
  });

  void _completePendingFailure(_PendingRequest? pending) {
    if (pending == null) return;
    _revertPending(pending);
    if (pending.kind == _PendingRequestKind.legacyImport) {
      _legacyImportInFlight = false;
    }
    if (pending.kind == _PendingRequestKind.disableAll) {
      _globalDisablePending = true;
      _lastDisableWasQueued = true;
      pending.completer?.complete(true);
    } else {
      pending.completer?.complete(false);
    }
  }

  void _completeOtherDisableRequests({String? excluding}) {
    final requests = _pendingRequests.values
        .where(
          (pending) =>
              pending.kind == _PendingRequestKind.disableAll &&
              pending.requestId != excluding,
        )
        .toList(growable: false);
    for (final request in requests) {
      _pendingRequests.remove(request.requestId);
      request.timer.cancel();
      request.completer?.complete(true);
    }
  }

  void _revertPending(_PendingRequest? pending) {
    if (pending?.kind == _PendingRequestKind.set &&
        pending?.providerSessionId != null) {
      _finishSettingIntent(pending!.providerSessionId!, pending.requestId);
    }
  }

  void _finishSettingIntent(String providerSessionId, String requestId) {
    if (_settingIntents[providerSessionId]?.requestId == requestId) {
      _settingIntents.remove(providerSessionId);
    }
  }

  void _failPendingRequests() {
    final pending = _pendingRequests.values.toList(growable: false);
    _pendingRequests.clear();
    for (final request in pending) {
      request.timer.cancel();
      _completePendingFailure(request);
    }
  }

  Future<void> _clearImportedLegacyKeys() async {
    final bridgeIdentity = _currentBridgeIdentity();
    if (bridgeIdentity == null) return;
    _legacyIdentityKeys.removeWhere((key) {
      final identity = _LegacyIdentity.tryParse(key);
      return identity?.bridgeIdentity == bridgeIdentity &&
          identity?.provider == Provider.codex.value;
    });
    await _preferences.setStringList(
      preferencesKey,
      _legacyIdentityKeys.toList()..sort(),
    );
    if (!_closed) notifyListeners();
  }

  _AutoApprovalTarget? _targetForRuntime(String runtimeSessionId) {
    for (final session in _bridge.sessions) {
      if (session.id == runtimeSessionId) return _targetForSession(session);
    }
    return null;
  }

  _AutoApprovalTarget? _targetForSession(SessionInfo session) {
    final providerSessionId = session.claudeSessionId?.trim();
    if (session.provider != Provider.codex.value ||
        providerSessionId == null ||
        providerSessionId.isEmpty) {
      return null;
    }
    return _AutoApprovalTarget(
      runtimeSessionId: session.id,
      providerSessionId: providerSessionId,
    );
  }

  String? _currentBridgeIdentity() {
    final logical = _bridge.logicalConnectionIdentity?.trim();
    if (logical != null && logical.isNotEmpty) return logical;
    final endpoint = sanitizeBridgeEndpoint(_bridge.lastUrl);
    return endpoint == null ? null : 'endpoint:$endpoint';
  }

  String _nextRequestId(String prefix) =>
      'auto-$prefix-${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';

  @visibleForTesting
  static String? sanitizeBridgeEndpoint(String? rawUrl) {
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'ws' && scheme != 'wss') return null;
    final port = uri.hasPort ? uri.port : (scheme == 'wss' ? 443 : 80);
    final path = uri.path.isEmpty ? '/' : uri.path;
    return Uri(
      scheme: scheme,
      host: uri.host.toLowerCase(),
      port: port,
      path: path,
    ).toString();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _failPendingRequests();
    unawaited(_sessionsSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_featureSubscription?.cancel());
    _sessionsSubscription = null;
    _connectionSubscription = null;
    _featureSubscription = null;
    super.dispose();
  }
}

enum _PendingRequestKind { query, set, disableAll, legacyImport }

class _PendingRequest {
  const _PendingRequest({
    required this.requestId,
    required this.kind,
    required this.timer,
    this.runtimeSessionId,
    this.providerSessionId,
    this.completer,
  });

  final String requestId;
  final _PendingRequestKind kind;
  final String? runtimeSessionId;
  final String? providerSessionId;
  final Completer<bool>? completer;
  final Timer timer;
}

class _SettingIntent {
  const _SettingIntent({required this.requestId, required this.enabled});

  final String requestId;
  final bool enabled;
}

class _AutoApprovalTarget {
  const _AutoApprovalTarget({
    required this.runtimeSessionId,
    required this.providerSessionId,
  });

  final String runtimeSessionId;
  final String providerSessionId;
}

class _LegacyIdentity {
  const _LegacyIdentity({
    required this.bridgeIdentity,
    required this.provider,
    required this.providerSessionId,
  });

  final String bridgeIdentity;
  final String provider;
  final String providerSessionId;

  static _LegacyIdentity? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List ||
          decoded.length != 4 ||
          decoded[0] != 1 ||
          decoded[1] is! String ||
          decoded[2] is! String ||
          decoded[3] is! String) {
        return null;
      }
      return _LegacyIdentity(
        bridgeIdentity: decoded[1] as String,
        provider: decoded[2] as String,
        providerSessionId: decoded[3] as String,
      );
    } catch (_) {
      return null;
    }
  }
}
