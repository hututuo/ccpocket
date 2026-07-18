// The public `bridge:` constructor name is an external module seam;
// `this._bridge` would make the named argument library-private.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logger.dart';
import '../../models/messages.dart';
import '../../services/bridge_service.dart';

typedef AutoApprovalPersistence =
    Future<bool> Function(List<String> enabledIdentityKeys);

/// Mobile-owned supervision for selected Codex conversations.
///
/// This intentionally reuses the long-standing one-shot `approve` wire
/// message. It never changes provider permission modes and never fabricates
/// answers for question prompts.
class AutoApprovalService extends ChangeNotifier {
  static const preferencesKey = 'local_feature.codex_auto_approval.enabled.v1';
  static const _maxAttemptsPerRequest = 3;
  static const _defaultMaxTrackedRequests = 512;

  AutoApprovalService({
    required BridgeService bridge,
    required SharedPreferences preferences,
    this._reconcileDelay = const Duration(seconds: 2),
    int maxTrackedRequests = _defaultMaxTrackedRequests,
    AutoApprovalPersistence? persistEnabledKeys,
  }) : _bridge = bridge,
       _maxTrackedRequests = maxTrackedRequests,
       _persistEnabledKeys =
           persistEnabledKeys ??
           ((values) => preferences.setStringList(preferencesKey, values)),
       _enabledIdentityKeys = {...?preferences.getStringList(preferencesKey)};

  final BridgeService _bridge;
  final Duration _reconcileDelay;
  final int _maxTrackedRequests;
  final AutoApprovalPersistence _persistEnabledKeys;
  final Set<String> _enabledIdentityKeys;
  final Map<String, _SettingIntent> _settingIntents = {};
  final Map<String, _ApprovalAttempt> _attempts = {};
  final Map<String, int> _approvalCounts = <String, int>{};
  Future<void> _settingsMutationTail = Future<void>.value();
  int _settingGeneration = 0;
  int _globalDisableGeneration = 0;
  bool _globalDisablePending = false;

  StreamSubscription<List<SessionInfo>>? _sessionsSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  VoidCallback? _removeObserver;
  bool _initialized = false;
  bool _closed = false;
  bool _awaitingFreshSessions = false;
  int _requiredAuthoritativeSessionListGeneration = 0;

  void initialize() {
    if (_initialized || _closed) return;
    _initialized = true;
    _removeObserver = _bridge.registerPermissionRequestObserver(
      _observePermissionRequest,
    );
    _sessionsSubscription = _bridge.sessionList.listen(_handleSessions);
    _connectionSubscription = _bridge.connectionStatus.listen((state) {
      if (state == BridgeConnectionState.connected) {
        _awaitingFreshSessions = true;
        _requiredAuthoritativeSessionListGeneration =
            _bridge.authoritativeSessionListGeneration + 1;
        _bridge.requestSessionList();
        notifyListeners();
      } else {
        _awaitingFreshSessions = true;
        _clearAttempts();
        notifyListeners();
      }
    });
    _handleSessions(_bridge.sessions);
  }

  bool canConfigureSession(String runtimeSessionId) =>
      _identityForRuntime(runtimeSessionId) != null;

  bool isEnabledForSession(String runtimeSessionId) {
    final identity = _identityForRuntime(runtimeSessionId);
    if (identity == null) return false;
    return _visibleEnabledState(identity.preferenceKey);
  }

  int approvedCountForSession(String runtimeSessionId) {
    final identity = _identityForRuntime(runtimeSessionId);
    if (identity == null) return 0;
    return _approvalCounts[identity.preferenceKey] ?? 0;
  }

  int get enabledConversationCount => _visibleEnabledIdentityKeys.length;

  bool get hasEnabledConversations => enabledConversationCount > 0;

  /// Immediately suppress every local auto-approval identity, then persist an
  /// empty allowlist. This intentionally does not require a live Bridge or a
  /// runtime session, so the user always has an offline emergency stop.
  Future<bool> disableAll() {
    if (_closed) return Future<bool>.value(false);
    final generation = ++_globalDisableGeneration;
    _globalDisablePending = true;
    _settingIntents.clear();
    _clearAttempts();
    notifyListeners();
    return _serializeSettingsMutation(() => _applyDisableAll(generation));
  }

  Future<bool> setEnabledForSession(String runtimeSessionId, bool enabled) {
    final identity = _identityForRuntime(runtimeSessionId);
    if (identity == null || _closed) return Future<bool>.value(false);
    final identityKey = identity.preferenceKey;
    if (_visibleEnabledState(identityKey) == enabled) {
      return Future<bool>.value(true);
    }

    final intent = _SettingIntent(
      identityKey: identityKey,
      runtimeSessionId: runtimeSessionId,
      enabled: enabled,
      generation: ++_settingGeneration,
    );
    _settingIntents[identityKey] = intent;
    // A requested disable must block approval synchronously, even while the
    // preference write waits behind another conversation's mutation.
    notifyListeners();
    return _serializeSettingsMutation(() => _applySettingIntent(intent));
  }

  Future<bool> _applySettingIntent(_SettingIntent intent) async {
    if (_closed) return false;
    final alreadyPersisted =
        _enabledIdentityKeys.contains(intent.identityKey) == intent.enabled;
    if (!alreadyPersisted) {
      try {
        final stored = intent.enabled
            ? {..._enabledIdentityKeys, intent.identityKey}.toList()
            : _enabledIdentityKeys
                  .where((key) => key != intent.identityKey)
                  .toList();
        stored.sort();
        final persisted = await _persistEnabledKeys(stored);
        if (!persisted || _closed) {
          _finishSettingIntent(intent);
          return false;
        }
        if (intent.enabled) {
          _enabledIdentityKeys.add(intent.identityKey);
        } else {
          _enabledIdentityKeys.remove(intent.identityKey);
          _clearAttempts(identityKey: intent.identityKey);
        }
      } catch (error, stackTrace) {
        logger.warning(
          '[auto-approval] Failed to persist setting',
          error,
          stackTrace,
        );
        _finishSettingIntent(intent);
        return false;
      }
    }

    _finishSettingIntent(intent);
    if (intent.enabled && _isApprovalActive(intent.identityKey)) {
      final session = _sessionByRuntimeId(intent.runtimeSessionId);
      final currentIdentity = session == null
          ? null
          : _identityForSession(session);
      final pending = session?.pendingPermission;
      if (session != null &&
          currentIdentity?.preferenceKey == intent.identityKey &&
          pending != null) {
        _tryAutoApprove(session, pending);
      }
    }
    return true;
  }

  bool _visibleEnabledState(String identityKey) =>
      _settingIntents[identityKey]?.enabled ??
      (!_globalDisablePending && _enabledIdentityKeys.contains(identityKey));

  Set<String> get _visibleEnabledIdentityKeys {
    final visible = _globalDisablePending
        ? <String>{}
        : <String>{..._enabledIdentityKeys};
    for (final intent in _settingIntents.values) {
      if (intent.enabled) {
        visible.add(intent.identityKey);
      } else {
        visible.remove(intent.identityKey);
      }
    }
    return visible;
  }

  bool _isApprovalActive(String identityKey) =>
      !_globalDisablePending &&
      _enabledIdentityKeys.contains(identityKey) &&
      _settingIntents[identityKey]?.enabled != false;

  void _finishSettingIntent(_SettingIntent intent) {
    final latest = _settingIntents[intent.identityKey];
    if (latest?.generation != intent.generation) return;
    _settingIntents.remove(intent.identityKey);
    if (!_closed) notifyListeners();
  }

  Future<bool> _applyDisableAll(int generation) async {
    try {
      final persisted = await _persistEnabledKeys(const []);
      if (!persisted || _closed) {
        _finishDisableAll(generation);
        return false;
      }
      _enabledIdentityKeys.clear();
      _clearAttempts();
      _finishDisableAll(generation);
      return true;
    } catch (error, stackTrace) {
      logger.warning(
        '[auto-approval] Failed to disable all supervision',
        error,
        stackTrace,
      );
      _finishDisableAll(generation);
      return false;
    }
  }

  void _finishDisableAll(int generation) {
    if (_globalDisableGeneration != generation) return;
    _globalDisablePending = false;
    if (!_closed) notifyListeners();
  }

  Future<T> _serializeSettingsMutation<T>(Future<T> Function() action) {
    final previous = _settingsMutationTail;
    final completion = Completer<void>();
    _settingsMutationTail = completion.future;
    return () async {
      try {
        await previous;
        return await action();
      } finally {
        if (!completion.isCompleted) completion.complete();
      }
    }();
  }

  void _observePermissionRequest(
    String runtimeSessionId,
    PermissionRequestMessage request,
  ) {
    if (_awaitingFreshSessions) return;
    final session = _sessionByRuntimeId(runtimeSessionId);
    if (session != null) _tryAutoApprove(session, request);
  }

  void _handleSessions(List<SessionInfo> sessions) {
    if (_closed) return;
    if (_bridge.isConnected) {
      if (_awaitingFreshSessions &&
          _bridge.authoritativeSessionListGeneration <
              _requiredAuthoritativeSessionListGeneration) {
        notifyListeners();
        return;
      }
      _awaitingFreshSessions = false;
      for (final session in sessions) {
        final pending = session.pendingPermission;
        if (pending != null) _tryAutoApprove(session, pending);
      }
    }
    notifyListeners();
  }

  bool _tryAutoApprove(SessionInfo session, PermissionRequestMessage request) {
    final identity = _identityForSession(session);
    if (_awaitingFreshSessions ||
        identity == null ||
        !_isApprovalActive(identity.preferenceKey) ||
        !_bridge.isConnected ||
        !isEligibleRequest(request)) {
      return false;
    }

    final requestKey = _requestKey(identity, session, request);
    final previousAttempt = _attempts[requestKey];
    if (previousAttempt == null && _attempts.length >= _maxTrackedRequests) {
      logger.warning(
        '[auto-approval] Tracking capacity reached; leaving '
        '${request.toolUseId} for manual approval',
      );
      return false;
    }
    if (previousAttempt != null &&
        (previousAttempt.attempts >= _maxAttemptsPerRequest ||
            DateTime.now().difference(previousAttempt.sentAt) <
                _reconcileDelay)) {
      return false;
    }

    try {
      _bridge.send(
        ClientMessage.approveLiveOnly(request.toolUseId, sessionId: session.id),
      );
      previousAttempt?.timer.cancel();
      final attempts = (previousAttempt?.attempts ?? 0) + 1;
      final timer = Timer(_reconcileDelay, () {
        if (!_closed && _bridge.isConnected) {
          _bridge.requestSessionList();
        }
      });
      _attempts[requestKey] = _ApprovalAttempt(
        identityKey: identity.preferenceKey,
        attempts: attempts,
        sentAt: DateTime.now(),
        timer: timer,
      );
      if (previousAttempt == null) {
        _approvalCounts.update(
          identity.preferenceKey,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      logger.info(
        '[auto-approval] Sent ${request.toolName} approval '
        'for session ${session.id} (attempt $attempts)',
      );
      notifyListeners();
      return true;
    } catch (error, stackTrace) {
      logger.error(
        '[auto-approval] Failed to approve ${request.toolUseId}',
        error,
        stackTrace,
      );
      return false;
    }
  }

  @visibleForTesting
  static bool isEligibleRequest(PermissionRequestMessage request) {
    if (!request.canApprove) return false;
    switch (request.toolName) {
      case 'Bash':
      case 'FileChange':
      case 'Permissions':
      case 'ExitPlanMode':
        return true;
      case 'McpElicitation':
        return _isCanonicalMcpApproval(request);
      default:
        return false;
    }
  }

  static bool _isCanonicalMcpApproval(PermissionRequestMessage request) {
    final input = request.input;
    return request.isQuestionApproval &&
        input['mode'] == 'form' &&
        request.availableDecisions.contains('accept') &&
        !input.containsKey('requestedSchema') &&
        !input.containsKey('url') &&
        !input.containsKey('appsNeedingAuth');
  }

  @visibleForTesting
  bool handlePermissionRequestForTest(
    String runtimeSessionId,
    PermissionRequestMessage request,
  ) {
    final session = _sessionByRuntimeId(runtimeSessionId);
    return session != null && _tryAutoApprove(session, request);
  }

  String _requestKey(
    _AutoApprovalIdentity identity,
    SessionInfo session,
    PermissionRequestMessage request,
  ) => jsonEncode([identity.preferenceKey, session.id, request.toolUseId]);

  void _clearAttempts({String? identityKey}) {
    final keys = identityKey == null
        ? _attempts.keys.toList()
        : _attempts.entries
              .where((entry) => entry.value.identityKey == identityKey)
              .map((entry) => entry.key)
              .toList();
    for (final key in keys) {
      _attempts.remove(key)?.timer.cancel();
    }
  }

  _AutoApprovalIdentity? _identityForRuntime(String runtimeSessionId) {
    final session = _sessionByRuntimeId(runtimeSessionId);
    return session == null ? null : _identityForSession(session);
  }

  SessionInfo? _sessionByRuntimeId(String runtimeSessionId) {
    for (final session in _bridge.sessions) {
      if (session.id == runtimeSessionId) return session;
    }
    return null;
  }

  _AutoApprovalIdentity? _identityForSession(SessionInfo session) {
    if (session.provider != Provider.codex.value) return null;
    final endpoint = sanitizeBridgeEndpoint(_bridge.lastUrl);
    if (endpoint == null) return null;
    final logicalBridgeIdentity = _bridge.logicalConnectionIdentity?.trim();
    final providerSessionId = session.claudeSessionId?.trim();
    if (providerSessionId == null || providerSessionId.isEmpty) return null;
    return _AutoApprovalIdentity(
      bridgeIdentity:
          logicalBridgeIdentity == null || logicalBridgeIdentity.isEmpty
          ? 'endpoint:$endpoint'
          : logicalBridgeIdentity,
      provider: Provider.codex.value,
      providerSessionId: providerSessionId,
    );
  }

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

  @visibleForTesting
  Set<String> get enabledIdentityKeysForTest =>
      Set.unmodifiable(_enabledIdentityKeys);

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _removeObserver?.call();
    _removeObserver = null;
    _clearAttempts();
    unawaited(_sessionsSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    _sessionsSubscription = null;
    _connectionSubscription = null;
    super.dispose();
  }
}

class _ApprovalAttempt {
  const _ApprovalAttempt({
    required this.identityKey,
    required this.attempts,
    required this.sentAt,
    required this.timer,
  });

  final String identityKey;
  final int attempts;
  final DateTime sentAt;
  final Timer timer;
}

class _SettingIntent {
  const _SettingIntent({
    required this.identityKey,
    required this.runtimeSessionId,
    required this.enabled,
    required this.generation,
  });

  final String identityKey;
  final String runtimeSessionId;
  final bool enabled;
  final int generation;
}

class _AutoApprovalIdentity {
  const _AutoApprovalIdentity({
    required this.bridgeIdentity,
    required this.provider,
    required this.providerSessionId,
  });

  final String bridgeIdentity;
  final String provider;
  final String providerSessionId;

  String get preferenceKey =>
      jsonEncode([1, bridgeIdentity, provider, providerSessionId]);
}
