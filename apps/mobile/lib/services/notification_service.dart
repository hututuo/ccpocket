import 'package:flutter/foundation.dart'
    show ChangeNotifier, TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../models/messages.dart';
import '../models/notification_preferences.dart';

enum NotificationPermissionStatus { unavailable, enabled, disabled }

class NotificationService extends ChangeNotifier {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  NotificationPreferences _preferences = NotificationPreferences.defaults;
  String? _activeSessionId;
  String? _activeProvider;
  bool _notifyScheduled = false;

  String? get activeSessionId => _activeSessionId;
  String? get activeProvider => _activeProvider;
  NotificationPreferences get preferences => _preferences;

  /// Called when the user taps a notification. The [payload] string
  /// (typically a sessionId) is forwarded.
  void Function(String? payload)? onNotificationTap;

  Future<void> init() async {
    if (kIsWeb) return;
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/launcher_icon',
    );
    const iosSettings = DarwinInitializationSettings(
      // Initializing the notification channel must not prompt on launch.
      // Permission is requested only when the user enables notifications or
      // explicitly requests it from Settings > Permission Management.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const macosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open CC Pocket',
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: macosSettings,
      linux: linuxSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    // Create the notification channel eagerly so FCM uses it instead of
    // the low-priority fcm_fallback_notification_channel.
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          'ccpocket_channel',
          'ccpocket',
          description: 'Claude Code session notifications',
          importance: Importance.high,
        ),
      );
    }

    _initialized = true;
  }

  void configure(NotificationPreferences preferences) {
    if (_preferences == preferences) return;
    _preferences = preferences;
    _notifyListenersSafely();
  }

  bool allowsRemoteEvent(String eventType, {required bool appIsForeground}) {
    if (!_preferences.allowsRemoteEvent(eventType)) return false;
    return !appIsForeground || _preferences.showWhileAppOpen;
  }

  Future<NotificationPermissionStatus> permissionStatus() async {
    if (kIsWeb) return NotificationPermissionStatus.unavailable;
    await init();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final plugin = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final status = await plugin?.checkPermissions();
      if (status == null) return NotificationPermissionStatus.unavailable;
      return status.isEnabled
          ? NotificationPermissionStatus.enabled
          : NotificationPermissionStatus.disabled;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final plugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final enabled = await plugin?.areNotificationsEnabled();
      if (enabled == null) return NotificationPermissionStatus.unavailable;
      return enabled
          ? NotificationPermissionStatus.enabled
          : NotificationPermissionStatus.disabled;
    }

    return NotificationPermissionStatus.enabled;
  }

  Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    await init();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final plugin = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      return await plugin?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final plugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await plugin?.requestNotificationsPermission() ?? false;
    }

    return true;
  }

  void _onNotificationResponse(NotificationResponse response) {
    onNotificationTap?.call(response.payload);
  }

  void setActiveSession({required String sessionId, required String provider}) {
    if (_activeSessionId == sessionId && _activeProvider == provider) return;
    _activeSessionId = sessionId;
    _activeProvider = provider;
    _notifyListenersSafely();
  }

  void clearActiveSession({String? sessionId, String? provider}) {
    if (sessionId != null && _activeSessionId != sessionId) return;
    if (provider != null && _activeProvider != provider) return;
    if (_activeSessionId == null && _activeProvider == null) return;
    _activeSessionId = null;
    _activeProvider = null;
    _notifyListenersSafely();
  }

  void _notifyListenersSafely() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final canNotifyNow =
        phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks;
    if (canNotifyNow) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  bool isActiveSession({required String sessionId, required String provider}) {
    return _activeSessionId == sessionId && _activeProvider == provider;
  }

  /// Dismiss all previously shown notifications from the notification center.
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }

  Future<void> show({
    required String title,
    required String body,
    int id = 0,
    String? payload,
  }) async {
    if (!_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      'ccpocket_channel',
      'ccpocket',
      channelDescription: 'Claude Code session notifications',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const macosDetails = DarwinNotificationDetails();
    const linuxDetails = LinuxNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: macosDetails,
      linux: linuxDetails,
    );

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  Future<void> showApprovalNotification(
    PermissionRequestMessage permission, {
    required AppLocalizations l,
    int id = 1,
    String? payload,
  }) {
    if (!_preferences.actionRequired) return Future<void>.value();
    final copy = ApprovalNotificationCopy.from(permission, l: l);
    return show(title: copy.title, body: copy.body, id: id, payload: payload);
  }

  Future<void> showSessionCompleteNotification({
    required String body,
    int id = 3,
    String? payload,
  }) {
    if (!_preferences.taskCompleted) return Future<void>.value();
    return show(
      title: 'Session Complete',
      body: body,
      id: id,
      payload: payload,
    );
  }
}

class ApprovalNotificationCopy {
  final String title;
  final String body;

  const ApprovalNotificationCopy({required this.title, required this.body});

  factory ApprovalNotificationCopy.from(
    PermissionRequestMessage message, {
    required AppLocalizations l,
  }) {
    if (message.usesAskUserUi) {
      return ApprovalNotificationCopy(
        title: l.approvalQuestionNotificationTitle,
        body: message.summary,
      );
    }
    if (message.toolName == 'ExitPlanMode') {
      return ApprovalNotificationCopy(
        title: l.approvalRequiredNotificationTitle,
        body: l.exitPlanModeNotificationBody,
      );
    }

    final presentation = message.presentation;
    return ApprovalNotificationCopy(
      title: l.approvalRequiredNotificationTitle,
      body: presentation.summary,
    );
  }
}
