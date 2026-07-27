import 'dart:async';

import 'package:ccpocket/features/background_sync/background_location_keep_alive_host.dart';
import 'package:ccpocket/features/background_sync/background_notification_mode_controller.dart';
import 'package:ccpocket/features/permission_management/permission_host_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/models/notification_preferences.dart';
import 'package:ccpocket/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      backgroundLocationKeepAlivePreferenceKey: true,
    });
  });

  test(
    'background uses notification-only delivery and foreground restores it first',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final host = _FakeLocationHost(_authorizedSnapshot());
      final delivery = _FakeDelivery(activeWorkCount: 1);
      final presenter = _FakePresenter();
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: host,
        delivery: delivery,
        permissionHost: PermissionHostService.test(
          gateway: _FakePermissionGateway(),
        ),
        notifications: presenter,
      );
      await controller.initialize();
      controller.updatePolicy(
        preferences: const NotificationPreferences(progress: true),
        locale: 'zh-Hans',
        privacyMode: true,
      );

      await controller.prepareForBackground(hasBackgroundWork: true);
      expect(host.startCount, 1);
      expect(controller.state.phase, 'prepared');

      expect(await controller.enterBackground(hasBackgroundWork: true), isTrue);
      expect(delivery.modes, [BridgeClientDeliveryMode.notificationsOnly]);
      expect(delivery.locales, ['zh']);
      expect(delivery.privacyModes, [true]);
      expect(controller.state.phase, 'receiving_notifications_only');

      delivery.emitNotification(
        BackgroundNotificationMessage(
          eventType: NotificationPreferences.sessionProgressEvent,
          sessionId: 'session-1',
          provider: 'codex',
          title: '当前进度',
          body: '正在检查文件',
          occurredAt: DateTime(2026, 7, 24),
          data: const {},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(presenter.shown.single.sessionId, 'session-1');

      await controller.enterForeground();

      expect(delivery.modes, [
        BridgeClientDeliveryMode.notificationsOnly,
        BridgeClientDeliveryMode.interactive,
      ]);
      expect(host.stopCount, 1);
      expect(host.active, isFalse);
      await controller.dispose();
    },
  );

  test(
    'low power mode prevents transport engagement and location work',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final host = _FakeLocationHost(
        _authorizedSnapshot(lowPowerModeEnabled: true),
      );
      final delivery = _FakeDelivery(activeWorkCount: 1);
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: host,
        delivery: delivery,
        permissionHost: PermissionHostService.test(
          gateway: _FakePermissionGateway(),
        ),
        notifications: _FakePresenter(),
      );
      await controller.initialize();

      expect(
        await controller.enterBackground(hasBackgroundWork: true),
        isFalse,
      );
      expect(controller.state.phase, 'low_power_mode');
      expect(delivery.modes, isEmpty);
      expect(host.startCount, 0);
      await controller.dispose();
    },
  );

  test(
    'the keep-alive stops as soon as the Bridge reports no active work',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final host = _FakeLocationHost(_authorizedSnapshot());
      final delivery = _FakeDelivery(activeWorkCount: 1);
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: host,
        delivery: delivery,
        permissionHost: PermissionHostService.test(
          gateway: _FakePermissionGateway(),
        ),
        notifications: _FakePresenter(),
      );
      await controller.initialize();

      expect(await controller.enterBackground(hasBackgroundWork: true), isTrue);
      delivery.emitActivity(0);
      await Future<void>.delayed(Duration.zero);

      expect(host.active, isFalse);
      expect(controller.state.phase, 'waiting_for_active_task');
      await controller.dispose();
    },
  );

  test(
    'a prearmed location lease stops if active work ends before background',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final host = _FakeLocationHost(_authorizedSnapshot());
      final delivery = _FakeDelivery(activeWorkCount: 1);
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: host,
        delivery: delivery,
        permissionHost: PermissionHostService.test(
          gateway: _FakePermissionGateway(),
        ),
        notifications: _FakePresenter(),
      );
      await controller.initialize();

      await controller.prepareForBackground(hasBackgroundWork: true);
      expect(host.active, isTrue);

      expect(
        await controller.enterBackground(hasBackgroundWork: false),
        isFalse,
      );
      expect(host.active, isFalse);
      expect(host.stopCount, 1);
      expect(controller.state.phase, 'waiting_for_active_task');
      await controller.dispose();
    },
  );

  test(
    'a delayed background negotiation cannot reclaim foreground ownership',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final host = _FakeLocationHost(_authorizedSnapshot());
      final delivery = _FakeDelivery(
        activeWorkCount: 1,
        holdNotificationMode: true,
      );
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: host,
        delivery: delivery,
        permissionHost: PermissionHostService.test(
          gateway: _FakePermissionGateway(),
        ),
        notifications: _FakePresenter(),
      );
      await controller.initialize();

      final enteringBackground = controller.enterBackground(
        hasBackgroundWork: true,
      );
      await delivery.notificationModeStarted.future;
      expect(controller.ownsBackgroundTransport, isTrue);
      await controller.enterForeground();
      delivery.releaseNotificationMode();

      expect(await enteringBackground, isFalse);
      expect(controller.ownsBackgroundTransport, isFalse);
      expect(host.active, isFalse);
      expect(delivery.modes, [
        BridgeClientDeliveryMode.notificationsOnly,
        BridgeClientDeliveryMode.interactive,
      ]);
      await controller.dispose();
    },
  );

  test('a prolonged Bridge disconnect releases the location lease', () async {
    final preferences = await SharedPreferences.getInstance();
    final host = _FakeLocationHost(_authorizedSnapshot());
    final delivery = _FakeDelivery(activeWorkCount: 1);
    final controller = BackgroundNotificationModeController(
      preferences: preferences,
      locationHost: host,
      delivery: delivery,
      permissionHost: PermissionHostService.test(
        gateway: _FakePermissionGateway(),
      ),
      notifications: _FakePresenter(),
      disconnectedPowerGrace: Duration.zero,
    );
    await controller.initialize();
    expect(await controller.enterBackground(hasBackgroundWork: true), isTrue);
    expect(host.active, isTrue);

    delivery.emitConnection(BridgeConnectionState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(host.active, isFalse);
    expect(delivery.modes, [
      BridgeClientDeliveryMode.notificationsOnly,
      BridgeClientDeliveryMode.notificationsOnly,
    ]);
    expect(delivery.privacyModes, [false, true]);
    expect(controller.ownsBackgroundTransport, isFalse);
    expect(controller.state.phase, 'bridge_disconnected_power_pause');
    await controller.dispose();
  });

  test(
    'foreground restoration records interactive intent while disconnected',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final host = _FakeLocationHost(_authorizedSnapshot());
      final delivery = _FakeDelivery(activeWorkCount: 1);
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: host,
        delivery: delivery,
        permissionHost: PermissionHostService.test(
          gateway: _FakePermissionGateway(),
        ),
        notifications: _FakePresenter(),
      );
      await controller.initialize();
      expect(await controller.enterBackground(hasBackgroundWork: true), isTrue);

      delivery.isConnected = false;
      await controller.enterForeground();

      expect(delivery.modes, [
        BridgeClientDeliveryMode.notificationsOnly,
        BridgeClientDeliveryMode.interactive,
      ]);
      expect(controller.ownsBackgroundTransport, isFalse);
      await controller.dispose();
    },
  );

  test('an old Bridge falls back without starting location updates', () async {
    final preferences = await SharedPreferences.getInstance();
    final host = _FakeLocationHost(_authorizedSnapshot());
    final delivery = _FakeDelivery(
      activeWorkCount: 1,
      supportsNotificationOnly: false,
    );
    final controller = BackgroundNotificationModeController(
      preferences: preferences,
      locationHost: host,
      delivery: delivery,
      permissionHost: PermissionHostService.test(
        gateway: _FakePermissionGateway(),
      ),
      notifications: _FakePresenter(),
    );
    await controller.initialize();

    expect(await controller.enterBackground(hasBackgroundWork: true), isFalse);
    expect(controller.state.phase, 'bridge_update_required');
    expect(host.startCount, 0);
    await controller.dispose();
  });

  test('enabling is the only path that requests Always Location', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final host = _FakeLocationHost(_authorizedSnapshot());
    final permissionGateway = _FakePermissionGateway();
    final presenter = _FakePresenter();
    final controller = BackgroundNotificationModeController(
      preferences: preferences,
      locationHost: host,
      delivery: _FakeDelivery(activeWorkCount: 1),
      permissionHost: PermissionHostService.test(gateway: permissionGateway),
      notifications: presenter,
    );
    await controller.initialize();
    expect(permissionGateway.requests, isEmpty);

    await controller.setEnabledFromUserAction(true);

    expect(presenter.permissionRequestCount, 1);
    expect(permissionGateway.requests, [MobilePermission.locationAlways]);
    expect(
      preferences.getBool(backgroundLocationKeepAlivePreferenceKey),
      isTrue,
    );
    await controller.dispose();
  });

  test(
    'disabled notification permission prevents location and Bridge engagement',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final host = _FakeLocationHost(_authorizedSnapshot());
      final delivery = _FakeDelivery(activeWorkCount: 1);
      final presenter = _FakePresenter(
        status: NotificationPermissionStatus.disabled,
      );
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: host,
        delivery: delivery,
        permissionHost: PermissionHostService.test(
          gateway: _FakePermissionGateway(),
        ),
        notifications: presenter,
      );

      await controller.initialize();

      expect(controller.state.phase, 'notification_permission_required');
      expect(
        await controller.enterBackground(hasBackgroundWork: true),
        isFalse,
      );
      expect(delivery.modes, isEmpty);
      expect(host.startCount, 0);
      await controller.dispose();
    },
  );

  test(
    'denying notifications does not request Always Location unnecessarily',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final permissionGateway = _FakePermissionGateway();
      final presenter = _FakePresenter(
        status: NotificationPermissionStatus.disabled,
        permissionRequestResult: false,
      );
      final controller = BackgroundNotificationModeController(
        preferences: preferences,
        locationHost: _FakeLocationHost(_authorizedSnapshot()),
        delivery: _FakeDelivery(activeWorkCount: 1),
        permissionHost: PermissionHostService.test(gateway: permissionGateway),
        notifications: presenter,
      );
      await controller.initialize();

      await controller.setEnabledFromUserAction(true);

      expect(presenter.permissionRequestCount, 1);
      expect(permissionGateway.requests, isEmpty);
      expect(controller.state.phase, 'notification_permission_required');
      await controller.dispose();
    },
  );
}

BackgroundLocationKeepAliveSnapshot _authorizedSnapshot({
  bool active = false,
  bool lowPowerModeEnabled = false,
}) {
  return BackgroundLocationKeepAliveSnapshot(
    supported: true,
    nativeApiVersion: 1,
    authorization: BackgroundLocationAuthorization.authorizedAlways,
    active: active,
    lowPowerModeEnabled: lowPowerModeEnabled,
    thermalState: 'nominal',
  );
}

class _FakeLocationHost implements BackgroundLocationKeepAliveHost {
  _FakeLocationHost(this.snapshot);

  BackgroundLocationKeepAliveSnapshot snapshot;
  final _status =
      StreamController<BackgroundLocationKeepAliveSnapshot>.broadcast();
  int startCount = 0;
  int stopCount = 0;
  bool disposed = false;

  bool get active => snapshot.active;

  @override
  bool get supportsKeepAlive => snapshot.supported;

  @override
  Stream<BackgroundLocationKeepAliveSnapshot> get statusChanges =>
      _status.stream;

  @override
  Future<BackgroundLocationKeepAliveSnapshot> getSnapshot() async => snapshot;

  @override
  Future<BackgroundLocationKeepAliveSnapshot> start() async {
    startCount++;
    if (snapshot.hasAlwaysAuthorization &&
        !snapshot.lowPowerModeEnabled &&
        snapshot.thermalState != 'serious' &&
        snapshot.thermalState != 'critical') {
      snapshot = _copySnapshot(snapshot, active: true);
    }
    return snapshot;
  }

  @override
  Future<BackgroundLocationKeepAliveSnapshot> stop() async {
    stopCount++;
    snapshot = _copySnapshot(snapshot, active: false);
    return snapshot;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _status.close();
  }
}

BackgroundLocationKeepAliveSnapshot _copySnapshot(
  BackgroundLocationKeepAliveSnapshot value, {
  required bool active,
}) {
  return BackgroundLocationKeepAliveSnapshot(
    supported: value.supported,
    nativeApiVersion: value.nativeApiVersion,
    authorization: value.authorization,
    active: active,
    lowPowerModeEnabled: value.lowPowerModeEnabled,
    thermalState: value.thermalState,
    pauseReason: value.pauseReason,
  );
}

class _FakeDelivery implements BackgroundNotificationDeliveryGateway {
  _FakeDelivery({
    required this.activeWorkCount,
    this.supportsNotificationOnly = true,
    this.holdNotificationMode = false,
  });

  int activeWorkCount;
  bool holdNotificationMode;
  final notificationModeStarted = Completer<void>();
  final _notificationModeRelease = Completer<void>();
  @override
  bool supportsNotificationOnly;
  @override
  bool isConnected = true;
  final modes = <BridgeClientDeliveryMode>[];
  final locales = <String>[];
  final privacyModes = <bool>[];
  final _connections = StreamController<BridgeConnectionState>.broadcast();
  final _capabilities = StreamController<void>.broadcast();
  final _notifications =
      StreamController<BackgroundNotificationMessage>.broadcast();
  final _activities =
      StreamController<BackgroundActivityStateMessage>.broadcast();

  @override
  Stream<BridgeConnectionState> get connectionStates => _connections.stream;
  @override
  Stream<void> get capabilityChanges => _capabilities.stream;
  @override
  Stream<BackgroundNotificationMessage> get notifications =>
      _notifications.stream;
  @override
  Stream<BackgroundActivityStateMessage> get activityStates =>
      _activities.stream;

  @override
  Future<ClientDeliveryModeStateMessage?> setMode({
    required BridgeClientDeliveryMode mode,
    required String locale,
    required bool privacyMode,
    required List<String> enabledEventTypes,
  }) async {
    modes.add(mode);
    locales.add(locale);
    privacyModes.add(privacyMode);
    if (mode == BridgeClientDeliveryMode.notificationsOnly &&
        holdNotificationMode) {
      holdNotificationMode = false;
      if (!notificationModeStarted.isCompleted) {
        notificationModeStarted.complete();
      }
      await _notificationModeRelease.future;
    }
    return ClientDeliveryModeStateMessage(
      mode: mode,
      requestId: 'request-${modes.length}',
      activeWorkCount: activeWorkCount,
    );
  }

  void emitNotification(BackgroundNotificationMessage notification) {
    _notifications.add(notification);
  }

  void emitActivity(int count) {
    activeWorkCount = count;
    _activities.add(
      BackgroundActivityStateMessage(
        activeWorkCount: count,
        occurredAt: DateTime(2026, 7, 24),
      ),
    );
  }

  void emitConnection(BridgeConnectionState state) {
    isConnected = state == BridgeConnectionState.connected;
    _connections.add(state);
  }

  void releaseNotificationMode() {
    if (!_notificationModeRelease.isCompleted) {
      _notificationModeRelease.complete();
    }
  }
}

class _FakePresenter implements BackgroundNotificationPresenter {
  _FakePresenter({
    this.status = NotificationPermissionStatus.enabled,
    this.permissionRequestResult = true,
  });

  final NotificationPermissionStatus status;
  final bool permissionRequestResult;
  int permissionRequestCount = 0;
  final shown = <BackgroundNotificationMessage>[];

  @override
  Future<NotificationPermissionStatus> permissionStatus() async => status;

  @override
  Future<bool> requestPermission() async {
    permissionRequestCount++;
    return permissionRequestResult;
  }

  @override
  Future<void> show(BackgroundNotificationMessage notification) async {
    shown.add(notification);
  }
}

class _FakePermissionGateway implements PermissionHostGateway {
  final requests = <MobilePermission>[];

  @override
  Future<PermissionHostSnapshot> getSnapshot() async => _snapshot();

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<PermissionHostSnapshot> requestPermission(
    MobilePermission permission,
  ) async {
    requests.add(permission);
    return _snapshot();
  }

  PermissionHostSnapshot _snapshot() {
    return const PermissionHostSnapshot(
      supported: true,
      nativeApiVersion: 3,
      permissions: {
        MobilePermission.locationAlways: MobilePermissionState(
          permission: MobilePermission.locationAlways,
          status: MobilePermissionStatus.authorizedAlways,
          requestMode: MobilePermissionRequestMode.none,
        ),
      },
    );
  }
}
