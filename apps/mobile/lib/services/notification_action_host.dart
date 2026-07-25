import 'dart:async';

import 'package:flutter/services.dart';

const notificationActionHostChannelName = 'ccpocket/notification_actions';
const notificationActionHostNativeApiVersion = 1;

class NotificationApprovalActionEvent {
  const NotificationApprovalActionEvent({
    required this.actionId,
    required this.sessionId,
    required this.provider,
    required this.permissionId,
    required this.occurredAt,
    this.providerSessionId,
  });

  final String actionId;
  final String sessionId;
  final String provider;
  final String? providerSessionId;
  final String permissionId;
  final DateTime occurredAt;

  static NotificationApprovalActionEvent? fromChannelValue(Object? value) {
    if (value is! Map) return null;
    final data = Map<Object?, Object?>.from(value);
    final actionId = _boundedString(data['actionId'], 64);
    final sessionId = _boundedString(data['sessionId'], 256);
    final provider = _boundedString(data['provider'], 16);
    final providerSessionId = _boundedString(data['providerSessionId'], 256);
    final permissionId = _boundedString(data['permissionId'], 256);
    final occurredAt = DateTime.tryParse(
      _boundedString(data['occurredAt'], 64) ?? '',
    )?.toUtc();
    if ((actionId != 'ccpocket_approve_once_v1' &&
            actionId != 'ccpocket_reject_v1') ||
        sessionId == null ||
        (provider != 'claude' && provider != 'codex') ||
        permissionId == null ||
        occurredAt == null) {
      return null;
    }
    return NotificationApprovalActionEvent(
      actionId: actionId!,
      sessionId: sessionId,
      provider: provider!,
      providerSessionId: providerSessionId,
      permissionId: permissionId,
      occurredAt: occurredAt,
    );
  }
}

abstract interface class NotificationActionHost {
  bool get supportsApprovalActions;
  Stream<NotificationApprovalActionEvent> get approvalActions;

  Future<void> initialize();
  Future<void> dispose();
}

class MethodChannelNotificationActionHost implements NotificationActionHost {
  MethodChannelNotificationActionHost({
    required bool supportedByInstalledHost,
    MethodChannel? channel,
  }) : _supportsApprovalActions = supportedByInstalledHost,
       _channel =
           channel ?? const MethodChannel(notificationActionHostChannelName);

  final bool _supportsApprovalActions;
  final MethodChannel _channel;
  final StreamController<NotificationApprovalActionEvent> _actions =
      StreamController<NotificationApprovalActionEvent>.broadcast();
  bool _initialized = false;

  @override
  bool get supportsApprovalActions => _supportsApprovalActions;

  @override
  Stream<NotificationApprovalActionEvent> get approvalActions =>
      _actions.stream;

  @override
  Future<void> initialize() async {
    if (_initialized || !_supportsApprovalActions) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      final status = await _channel.invokeMapMethod<Object?, Object?>(
        'setDartReady',
      );
      final supported = status?['supported'];
      final version = status?['nativeApiVersion'];
      if (supported != true ||
          version is! int ||
          version < notificationActionHostNativeApiVersion) {
        _channel.setMethodCallHandler(null);
        _initialized = false;
      }
    } on MissingPluginException {
      _channel.setMethodCallHandler(null);
      _initialized = false;
    } on PlatformException {
      _channel.setMethodCallHandler(null);
      _initialized = false;
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'approvalAction') return;
    final event = NotificationApprovalActionEvent.fromChannelValue(
      call.arguments,
    );
    if (event != null && !_actions.isClosed) {
      _actions.add(event);
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _actions.close();
  }
}

String? _boundedString(Object? value, int maximumLength) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > maximumLength) return null;
  return trimmed;
}
