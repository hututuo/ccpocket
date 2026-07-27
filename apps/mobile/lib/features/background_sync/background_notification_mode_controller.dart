import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logger.dart';
import '../../models/messages.dart';
import '../../models/notification_preferences.dart';
import '../../services/bridge_service.dart';
import '../../services/notification_service.dart';
import '../permission_management/permission_host_service.dart';
import 'background_location_keep_alive_host.dart';

// Public constructor labels intentionally describe injected collaborators;
// initializing formals would expose private field names to callers.
// ignore_for_file: prefer_initializing_formals

const backgroundLocationKeepAlivePreferenceKey =
    'background_location_keep_alive_enabled_v1';

abstract interface class BackgroundNotificationDeliveryGateway {
  bool get isConnected;
  bool get supportsNotificationOnly;
  Stream<BridgeConnectionState> get connectionStates;
  Stream<void> get capabilityChanges;
  Stream<BackgroundNotificationMessage> get notifications;
  Stream<BackgroundActivityStateMessage> get activityStates;

  Future<ClientDeliveryModeStateMessage?> setMode({
    required BridgeClientDeliveryMode mode,
    required String locale,
    required bool privacyMode,
    required List<String> enabledEventTypes,
  });
}

class BridgeServiceBackgroundNotificationDeliveryGateway
    implements BackgroundNotificationDeliveryGateway {
  const BridgeServiceBackgroundNotificationDeliveryGateway(this._bridge);

  final BridgeService _bridge;

  @override
  bool get isConnected => _bridge.isTransportHealthy;

  @override
  bool get supportsNotificationOnly =>
      _bridge.supportsBackgroundNotificationDelivery;

  @override
  Stream<BridgeConnectionState> get connectionStates =>
      _bridge.connectionStatus;

  @override
  Stream<void> get capabilityChanges => _bridge.sessionList.map<void>((_) {});

  @override
  Stream<BackgroundNotificationMessage> get notifications =>
      _bridge.backgroundNotifications;

  @override
  Stream<BackgroundActivityStateMessage> get activityStates =>
      _bridge.backgroundActivityStates;

  @override
  Future<ClientDeliveryModeStateMessage?> setMode({
    required BridgeClientDeliveryMode mode,
    required String locale,
    required bool privacyMode,
    required List<String> enabledEventTypes,
  }) {
    return _bridge.setClientDeliveryMode(
      mode: mode,
      locale: locale,
      privacyMode: privacyMode,
      enabledEventTypes: enabledEventTypes,
    );
  }
}

abstract interface class BackgroundNotificationPresenter {
  Future<NotificationPermissionStatus> permissionStatus();
  Future<bool> requestPermission();
  Future<void> show(BackgroundNotificationMessage notification);
}

class NotificationServiceBackgroundPresenter
    implements BackgroundNotificationPresenter {
  const NotificationServiceBackgroundPresenter(this._service);

  final NotificationService _service;

  @override
  Future<NotificationPermissionStatus> permissionStatus() async {
    try {
      return await _service.permissionStatus();
    } catch (error, stackTrace) {
      logger.warning(
        '[background-notifications] permission status unavailable',
        error,
        stackTrace,
      );
      return NotificationPermissionStatus.unavailable;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _service.requestPermission();
    } catch (error, stackTrace) {
      logger.warning(
        '[background-notifications] permission request failed',
        error,
        stackTrace,
      );
      return false;
    }
  }

  @override
  Future<void> show(BackgroundNotificationMessage notification) async {
    if (!_service.allowsRemoteEvent(
      notification.eventType,
      appIsForeground: false,
    )) {
      return;
    }
    final permissionId =
        notification.data['permissionId'] ?? notification.data['toolUseId'];
    final payload = encodeSessionNotificationPayload(
      sessionId: notification.sessionId,
      provider: notification.provider,
      providerSessionId: notification.data['providerSessionId'],
      eventType: notification.eventType,
      permissionId: permissionId,
      occurredAt: notification.occurredAt,
    );
    await _service.show(
      title: notification.title,
      body: notification.body,
      payload: payload,
      id: Object.hash(
        notification.sessionId,
        notification.provider,
        notification.eventType,
      ).abs(),
      categoryIdentifier:
          notification.eventType ==
                  NotificationPreferences.approvalRequiredEvent &&
              permissionId?.isNotEmpty == true
          ? approvalNotificationCategoryId
          : null,
    );
  }
}

@immutable
class BackgroundNotificationModeState {
  const BackgroundNotificationModeState({
    required this.initialized,
    required this.enabled,
    required this.busy,
    required this.bridgeSupported,
    required this.hostSnapshot,
    required this.notificationPermissionStatus,
    required this.activeWorkCount,
    required this.phase,
  });

  const BackgroundNotificationModeState.initial()
    : initialized = false,
      enabled = false,
      busy = false,
      bridgeSupported = false,
      hostSnapshot = const BackgroundLocationKeepAliveSnapshot.unavailable(
        'not_loaded',
      ),
      notificationPermissionStatus = NotificationPermissionStatus.unavailable,
      activeWorkCount = 0,
      phase = 'initializing';

  final bool initialized;
  final bool enabled;
  final bool busy;
  final bool bridgeSupported;
  final BackgroundLocationKeepAliveSnapshot hostSnapshot;
  final NotificationPermissionStatus notificationPermissionStatus;
  final int activeWorkCount;
  final String phase;

  bool get requiresBaseAppUpdate => !hostSnapshot.supported;
  bool get hasAlwaysAuthorization => hostSnapshot.hasAlwaysAuthorization;
  bool get active => hostSnapshot.active;
}

abstract interface class BackgroundNotificationModeLifecycle {
  bool get ownsBackgroundTransport;

  Future<void> prepareForBackground({required bool hasBackgroundWork});
  Future<bool> enterBackground({required bool hasBackgroundWork});
  Future<void> enterForeground();
  Future<void> leaveLifecycle();
}

class BackgroundNotificationModeController extends ChangeNotifier
    implements BackgroundNotificationModeLifecycle {
  BackgroundNotificationModeController({
    required SharedPreferences preferences,
    required BackgroundLocationKeepAliveHost locationHost,
    required BackgroundNotificationDeliveryGateway delivery,
    required PermissionHostService permissionHost,
    required BackgroundNotificationPresenter notifications,
    Duration disconnectedPowerGrace = const Duration(minutes: 2),
  }) : _preferences = preferences,
       _locationHost = locationHost,
       _delivery = delivery,
       _permissionHost = permissionHost,
       _notifications = notifications,
       _disconnectedPowerGrace = disconnectedPowerGrace;

  final SharedPreferences _preferences;
  final BackgroundLocationKeepAliveHost _locationHost;
  final BackgroundNotificationDeliveryGateway _delivery;
  final PermissionHostService _permissionHost;
  final BackgroundNotificationPresenter _notifications;
  final Duration _disconnectedPowerGrace;

  BackgroundNotificationModeState _state =
      const BackgroundNotificationModeState.initial();
  BackgroundNotificationModeState get state => _state;

  StreamSubscription<BackgroundNotificationMessage>? _notificationSub;
  StreamSubscription<BackgroundActivityStateMessage>? _activitySub;
  StreamSubscription<BackgroundLocationKeepAliveSnapshot>? _hostStatusSub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  StreamSubscription<void>? _capabilitySub;
  Timer? _disconnectedTimer;
  bool _isBackground = false;
  bool _deliveryEngaged = false;
  bool _notificationModeRequested = false;
  bool _prearmed = false;
  bool _recovering = false;
  bool _disposed = false;
  int _lifecycleOperationGeneration = 0;
  String _locale = 'en';
  bool _privacyMode = false;
  NotificationPreferences _notificationPreferences =
      NotificationPreferences.defaults;

  @override
  bool get ownsBackgroundTransport =>
      _isBackground && (_deliveryEngaged || _notificationModeRequested);

  Future<void> initialize() async {
    if (_state.initialized || _disposed) return;
    final enabled =
        _preferences.getBool(backgroundLocationKeepAlivePreferenceKey) ?? false;
    _notificationSub = _delivery.notifications.listen(_handleNotification);
    _activitySub = _delivery.activityStates.listen(_handleActivityState);
    _hostStatusSub = _locationHost.statusChanges.listen(_handleHostStatus);
    _connectionSub = _delivery.connectionStates.listen(_handleConnectionState);
    _capabilitySub = _delivery.capabilityChanges.listen((_) {
      final becameAvailable =
          !_state.bridgeSupported && _delivery.supportsNotificationOnly;
      _replaceState(
        bridgeSupported: _delivery.supportsNotificationOnly,
        phase: _state.phase,
      );
      if (becameAvailable && _isBackground && _state.enabled) {
        unawaited(_recoverBackgroundMode());
      }
    });
    final snapshot = await _locationHost.getSnapshot();
    final notificationPermissionStatus = await _notifications
        .permissionStatus();
    if (_disposed) return;
    _state = BackgroundNotificationModeState(
      initialized: true,
      enabled: enabled,
      busy: false,
      bridgeSupported: _delivery.supportsNotificationOnly,
      hostSnapshot: snapshot,
      notificationPermissionStatus: notificationPermissionStatus,
      activeWorkCount: 0,
      phase: _phaseForIdle(
        enabled: enabled,
        snapshot: snapshot,
        notificationPermissionStatus: notificationPermissionStatus,
      ),
    );
    notifyListeners();
  }

  void updatePolicy({
    required NotificationPreferences preferences,
    required String locale,
    required bool privacyMode,
  }) {
    _notificationPreferences = preferences;
    _locale = _normalizeLocale(locale);
    _privacyMode = privacyMode;
    if (_deliveryEngaged && _isBackground) {
      unawaited(_refreshBackgroundDeliveryPolicy());
    }
  }

  Future<void> setEnabledFromUserAction(bool enabled) async {
    if (_disposed) return;
    await initialize();
    _replaceState(enabled: enabled, busy: true, phase: 'updating_permission');
    await _preferences.setBool(
      backgroundLocationKeepAlivePreferenceKey,
      enabled,
    );
    if (!enabled) {
      final shouldRestoreInteractive =
          _deliveryEngaged || _notificationModeRequested;
      _deliveryEngaged = false;
      _notificationModeRequested = false;
      if (shouldRestoreInteractive) {
        await _setInteractiveDesiredMode();
      }
      final snapshot = await _locationHost.stop();
      _prearmed = false;
      _replaceState(
        enabled: false,
        busy: false,
        hostSnapshot: snapshot,
        phase: 'disabled',
      );
      return;
    }

    if (!_locationHost.supportsKeepAlive) {
      final snapshot = await _locationHost.getSnapshot();
      _replaceState(
        enabled: true,
        busy: false,
        hostSnapshot: snapshot,
        phase: 'base_app_update_required',
      );
      return;
    }
    await _notifications.requestPermission();
    final notificationPermissionStatus = await _notifications
        .permissionStatus();
    if (notificationPermissionStatus != NotificationPermissionStatus.enabled) {
      _replaceState(
        enabled: true,
        busy: false,
        notificationPermissionStatus: notificationPermissionStatus,
        phase:
            notificationPermissionStatus ==
                NotificationPermissionStatus.unavailable
            ? 'notification_permission_unavailable'
            : 'notification_permission_required',
      );
      return;
    }
    await _permissionHost.requestFromUserAction(
      MobilePermission.locationAlways,
    );
    final snapshot = await _locationHost.getSnapshot();
    _replaceState(
      enabled: true,
      busy: false,
      hostSnapshot: snapshot,
      notificationPermissionStatus: notificationPermissionStatus,
      phase: _phaseForIdle(
        enabled: true,
        snapshot: snapshot,
        notificationPermissionStatus: notificationPermissionStatus,
      ),
    );
  }

  Future<bool> openSystemSettings() => _permissionHost.openAppSettings();

  @override
  Future<void> prepareForBackground({required bool hasBackgroundWork}) async {
    if (_disposed) return;
    final operation = ++_lifecycleOperationGeneration;
    await initialize();
    if (operation != _lifecycleOperationGeneration || _disposed) return;
    if (!_canUseKeepAlive(hasBackgroundWork: hasBackgroundWork)) return;
    final snapshot = await _locationHost.start();
    if (operation != _lifecycleOperationGeneration || _disposed) return;
    _prearmed = snapshot.active;
    _replaceState(
      hostSnapshot: snapshot,
      phase: snapshot.active
          ? 'prepared'
          : (snapshot.pauseReason ?? 'location_start_failed'),
    );
  }

  @override
  Future<bool> enterBackground({required bool hasBackgroundWork}) async {
    if (_disposed) return false;
    final operation = ++_lifecycleOperationGeneration;
    await initialize();
    if (operation != _lifecycleOperationGeneration || _disposed) return false;
    _isBackground = true;
    return _engageBackgroundMode(
      operation: operation,
      hasBackgroundWork: hasBackgroundWork,
    );
  }

  Future<bool> _engageBackgroundMode({
    required int operation,
    required bool hasBackgroundWork,
  }) async {
    if (!_isCurrentBackgroundOperation(operation)) return false;
    if (!_canUseKeepAlive(
      hasBackgroundWork: hasBackgroundWork,
      requireBackgroundWork: false,
    )) {
      await _stopPrearmedLocation(operation);
      return false;
    }

    _notificationModeRequested = true;
    final mode = await _delivery.setMode(
      mode: BridgeClientDeliveryMode.notificationsOnly,
      locale: _locale,
      privacyMode: _privacyMode,
      enabledEventTypes: _notificationPreferences.enabledRemoteEventTypes,
    );
    if (!_isCurrentBackgroundOperation(operation)) return false;
    _notificationModeRequested = false;
    if (mode == null ||
        mode.mode != BridgeClientDeliveryMode.notificationsOnly) {
      await _locationHost.stop();
      _prearmed = false;
      _deliveryEngaged = false;
      _replaceState(phase: 'bridge_mode_unavailable');
      return false;
    }
    _deliveryEngaged = true;
    _replaceState(activeWorkCount: mode.activeWorkCount);
    if (mode.activeWorkCount <= 0) {
      final snapshot = await _locationHost.stop();
      if (!_isCurrentBackgroundOperation(operation)) return false;
      _prearmed = false;
      _replaceState(hostSnapshot: snapshot, phase: 'waiting_for_active_task');
      return true;
    }

    var snapshot = _state.hostSnapshot;
    if (!_prearmed || !snapshot.active) {
      snapshot = await _locationHost.start();
      if (!_isCurrentBackgroundOperation(operation)) return false;
    }
    _prearmed = snapshot.active;
    _replaceState(
      hostSnapshot: snapshot,
      phase: snapshot.active
          ? 'receiving_notifications_only'
          : (snapshot.pauseReason ?? 'location_start_failed'),
    );
    if (!snapshot.active) {
      _deliveryEngaged = false;
      await _setInteractiveDesiredMode();
      return false;
    }
    return true;
  }

  bool _isCurrentBackgroundOperation(int operation) {
    return !_disposed &&
        _isBackground &&
        operation == _lifecycleOperationGeneration;
  }

  Future<void> _stopPrearmedLocation(int operation) async {
    if (!_prearmed && !_state.hostSnapshot.active) return;
    final phase = _state.phase;
    final snapshot = await _locationHost.stop();
    if (operation != _lifecycleOperationGeneration || _disposed) return;
    _prearmed = false;
    _replaceState(hostSnapshot: snapshot, phase: phase);
  }

  @override
  Future<void> enterForeground() async {
    if (_disposed) return;
    final operation = ++_lifecycleOperationGeneration;
    _isBackground = false;
    _disconnectedTimer?.cancel();
    _disconnectedTimer = null;
    final shouldRestoreInteractive =
        _deliveryEngaged || _notificationModeRequested;
    _deliveryEngaged = false;
    _notificationModeRequested = false;
    if (shouldRestoreInteractive) {
      await _setInteractiveDesiredMode();
    }
    if (operation != _lifecycleOperationGeneration || _disposed) return;
    final snapshot = await _locationHost.stop();
    final notificationPermissionStatus = await _notifications
        .permissionStatus();
    if (operation != _lifecycleOperationGeneration || _disposed) return;
    _prearmed = false;
    _replaceState(
      hostSnapshot: snapshot,
      notificationPermissionStatus: notificationPermissionStatus,
      phase: _phaseForIdle(
        enabled: _state.enabled,
        snapshot: snapshot,
        notificationPermissionStatus: notificationPermissionStatus,
      ),
    );
  }

  @override
  Future<void> leaveLifecycle() async {
    if (_disposed) return;
    final operation = ++_lifecycleOperationGeneration;
    _isBackground = false;
    _disconnectedTimer?.cancel();
    _disconnectedTimer = null;
    final shouldRestoreInteractive =
        _deliveryEngaged || _notificationModeRequested;
    _deliveryEngaged = false;
    _notificationModeRequested = false;
    if (shouldRestoreInteractive) {
      await _setInteractiveDesiredMode();
    }
    if (operation != _lifecycleOperationGeneration || _disposed) return;
    _prearmed = false;
    final snapshot = await _locationHost.stop();
    if (operation != _lifecycleOperationGeneration || _disposed) return;
    _replaceState(hostSnapshot: snapshot, phase: 'lifecycle_inactive');
  }

  bool _canUseKeepAlive({
    required bool hasBackgroundWork,
    bool requireBackgroundWork = true,
  }) {
    final snapshot = _state.hostSnapshot;
    final phase = switch ((
      _state.enabled,
      _locationHost.supportsKeepAlive,
      _delivery.supportsNotificationOnly,
      _delivery.isConnected,
      requireBackgroundWork && !hasBackgroundWork,
      _state.notificationPermissionStatus,
      snapshot.hasAlwaysAuthorization,
      snapshot.lowPowerModeEnabled,
      snapshot.thermalState,
    )) {
      (false, _, _, _, _, _, _, _, _) => 'disabled',
      (_, false, _, _, _, _, _, _, _) => 'base_app_update_required',
      (_, _, false, _, _, _, _, _, _) => 'bridge_update_required',
      (_, _, _, false, _, _, _, _, _) => 'bridge_disconnected',
      (_, _, _, _, true, _, _, _, _) => 'waiting_for_active_task',
      (_, _, _, _, _, NotificationPermissionStatus.disabled, _, _, _) =>
        'notification_permission_required',
      (_, _, _, _, _, NotificationPermissionStatus.unavailable, _, _, _) =>
        'notification_permission_unavailable',
      (_, _, _, _, _, _, false, _, _) => 'location_always_required',
      (_, _, _, _, _, _, _, true, _) => 'low_power_mode',
      (_, _, _, _, _, _, _, _, 'serious' || 'critical') => 'thermal_pressure',
      _ => null,
    };
    if (phase == null) return true;
    _replaceState(
      bridgeSupported: _delivery.supportsNotificationOnly,
      phase: phase,
    );
    return false;
  }

  Future<void> _setInteractiveDesiredMode() async {
    await _delivery.setMode(
      mode: BridgeClientDeliveryMode.interactive,
      locale: _locale,
      privacyMode: _privacyMode,
      enabledEventTypes: _notificationPreferences.enabledRemoteEventTypes,
    );
  }

  Future<void> _refreshBackgroundDeliveryPolicy() async {
    if (!_deliveryEngaged || !_isBackground) return;
    await _delivery.setMode(
      mode: BridgeClientDeliveryMode.notificationsOnly,
      locale: _locale,
      privacyMode: _privacyMode,
      enabledEventTypes: _notificationPreferences.enabledRemoteEventTypes,
    );
  }

  void _handleNotification(BackgroundNotificationMessage notification) {
    if (!_isBackground ||
        !_state.enabled ||
        !_notificationPreferences.allowsRemoteEvent(notification.eventType)) {
      return;
    }
    unawaited(_notifications.show(notification));
  }

  void _handleActivityState(BackgroundActivityStateMessage state) {
    _replaceState(activeWorkCount: state.activeWorkCount);
    if (!_isBackground || !_deliveryEngaged) return;
    if (!state.hasActiveWork) {
      unawaited(_stopForNoActiveWork());
    } else if (!_state.hostSnapshot.active) {
      unawaited(_recoverBackgroundMode());
    }
  }

  Future<void> _stopForNoActiveWork() async {
    final operation = ++_lifecycleOperationGeneration;
    final snapshot = await _locationHost.stop();
    if (!_isCurrentBackgroundOperation(operation)) return;
    _prearmed = false;
    _replaceState(hostSnapshot: snapshot, phase: 'waiting_for_active_task');
  }

  void _handleHostStatus(BackgroundLocationKeepAliveSnapshot snapshot) {
    _prearmed = snapshot.active;
    _replaceState(
      hostSnapshot: snapshot,
      phase: snapshot.active
          ? _state.phase
          : (snapshot.pauseReason ?? _state.phase),
    );
  }

  void _handleConnectionState(BridgeConnectionState state) {
    if (!_isBackground || !_state.enabled) return;
    if (state == BridgeConnectionState.connected) {
      _disconnectedTimer?.cancel();
      _disconnectedTimer = null;
      unawaited(_recoverBackgroundMode());
      return;
    }
    if (state == BridgeConnectionState.disconnected) {
      // Reconnection can happen before machine-scoped settings are restored.
      // Fail private during that gap; a later settings update may relax the
      // policy again after the active machine identity is known.
      _privacyMode = true;
      if (_deliveryEngaged) {
        unawaited(_refreshBackgroundDeliveryPolicy());
      }
      _disconnectedTimer ??= Timer(
        _disconnectedPowerGrace,
        () => unawaited(_stopAfterDisconnectedGrace()),
      );
    }
  }

  Future<void> _recoverBackgroundMode() async {
    if (_recovering || !_isBackground || !_state.enabled) return;
    _recovering = true;
    final operation = ++_lifecycleOperationGeneration;
    try {
      await initialize();
      if (!_isCurrentBackgroundOperation(operation)) return;
      await _engageBackgroundMode(
        operation: operation,
        hasBackgroundWork: _state.activeWorkCount > 0,
      );
    } finally {
      _recovering = false;
    }
  }

  Future<void> _stopAfterDisconnectedGrace() async {
    if (!_isBackground || _delivery.isConnected) return;
    final operation = ++_lifecycleOperationGeneration;
    _deliveryEngaged = false;
    _notificationModeRequested = false;
    final snapshot = await _locationHost.stop();
    if (!_isCurrentBackgroundOperation(operation)) return;
    _prearmed = false;
    _replaceState(
      hostSnapshot: snapshot,
      phase: 'bridge_disconnected_power_pause',
    );
  }

  String _phaseForIdle({
    required bool enabled,
    required BackgroundLocationKeepAliveSnapshot snapshot,
    required NotificationPermissionStatus notificationPermissionStatus,
  }) {
    if (!enabled) return 'disabled';
    if (!snapshot.supported) return 'base_app_update_required';
    if (notificationPermissionStatus == NotificationPermissionStatus.disabled) {
      return 'notification_permission_required';
    }
    if (notificationPermissionStatus ==
        NotificationPermissionStatus.unavailable) {
      return 'notification_permission_unavailable';
    }
    if (!snapshot.hasAlwaysAuthorization) return 'location_always_required';
    if (snapshot.lowPowerModeEnabled) return 'low_power_mode';
    if (snapshot.thermalState == 'serious' ||
        snapshot.thermalState == 'critical') {
      return 'thermal_pressure';
    }
    if (!_delivery.supportsNotificationOnly) return 'bridge_update_required';
    return 'ready';
  }

  static String _normalizeLocale(String value) {
    final language = value.split(RegExp('[-_]')).first.toLowerCase();
    return switch (language) {
      'zh' || 'ja' || 'ko' => language,
      _ => 'en',
    };
  }

  void _replaceState({
    bool? enabled,
    bool? busy,
    bool? bridgeSupported,
    BackgroundLocationKeepAliveSnapshot? hostSnapshot,
    NotificationPermissionStatus? notificationPermissionStatus,
    int? activeWorkCount,
    String? phase,
  }) {
    if (_disposed) return;
    _state = BackgroundNotificationModeState(
      initialized: _state.initialized,
      enabled: enabled ?? _state.enabled,
      busy: busy ?? _state.busy,
      bridgeSupported: bridgeSupported ?? _delivery.supportsNotificationOnly,
      hostSnapshot: hostSnapshot ?? _state.hostSnapshot,
      notificationPermissionStatus:
          notificationPermissionStatus ?? _state.notificationPermissionStatus,
      activeWorkCount: activeWorkCount ?? _state.activeWorkCount,
      phase: phase ?? _state.phase,
    );
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _disconnectedTimer?.cancel();
    await _notificationSub?.cancel();
    await _activitySub?.cancel();
    await _hostStatusSub?.cancel();
    await _connectionSub?.cancel();
    await _capabilitySub?.cancel();
    if (_deliveryEngaged || _notificationModeRequested) {
      await _setInteractiveDesiredMode();
    }
    await _locationHost.stop();
    await _locationHost.dispose();
    super.dispose();
  }
}
