import 'dart:async';

import 'package:flutter/services.dart';

const notificationActionHostChannelName = 'ccpocket/notification_actions';
const notificationActionHostNativeApiVersion = 1;
const notificationActionHostCodexBrokerApiVersion = 2;

class NotificationApprovalActionEvent {
  const NotificationApprovalActionEvent({
    required this.actionId,
    required this.sessionId,
    required this.provider,
    required this.permissionId,
    required this.occurredAt,
    this.actionPayloadVersion = 1,
    this.providerSessionId,
    this.bridgeInstanceId,
    this.codexSourceId,
    this.bridgeRouteIdentity,
    this.threadId,
    this.turnId,
    this.authorityGeneration,
    this.allowedActions = const {},
  });

  final String actionId;
  final String sessionId;
  final String provider;
  final String? providerSessionId;
  final String? bridgeInstanceId;
  final String? codexSourceId;
  final String? bridgeRouteIdentity;
  final String permissionId;
  final DateTime occurredAt;
  final int actionPayloadVersion;
  final String? threadId;
  final String? turnId;
  final String? authorityGeneration;
  final Set<String> allowedActions;

  bool get usesCodexActionBroker => actionPayloadVersion == 2;

  static NotificationApprovalActionEvent? fromChannelValue(Object? value) {
    if (value is! Map) return null;
    final data = Map<Object?, Object?>.from(value);
    final actionId = _boundedString(data['actionId'], 64);
    final sessionId = _boundedString(data['sessionId'], 256);
    final provider = _boundedString(data['provider'], 16);
    final providerSessionId = _boundedString(data['providerSessionId'], 256);
    final bridgeInstanceId = _boundedString(data['bridgeInstanceId'], 256);
    final codexSourceId = bridgeInstanceId == null
        ? null
        : _boundedString(data['codexSourceId'], 256);
    final bridgeRouteIdentity = bridgeInstanceId == null
        ? _boundedString(data['bridgeRouteIdentity'], 1024)
        : null;
    final rawActionPayloadVersion = data['actionPayloadVersion'];
    final actionPayloadVersion = switch (rawActionPayloadVersion) {
      2 || '2' => 2,
      _ => 1,
    };
    final permissionId = actionPayloadVersion == 2
        ? _boundedString(data['opaqueRequestId'], 256)
        : _boundedString(data['permissionId'], 256);
    final occurredAt = DateTime.tryParse(
      _boundedString(data['occurredAt'], 64) ?? '',
    )?.toUtc();
    final allowedActions = actionPayloadVersion == 2
        ? _boundedActionSet(data['allowedActions'])
        : const <String>{};
    final threadId = _boundedString(data['threadId'], 256);
    final turnId = _boundedString(data['turnId'], 256);
    final authorityGeneration = _boundedString(data['authorityGeneration'], 64);
    if ((actionId != 'ccpocket_approve_once_v1' &&
            actionId != 'ccpocket_reject_v1') ||
        sessionId == null ||
        (provider != 'claude' && provider != 'codex') ||
        permissionId == null ||
        occurredAt == null ||
        (rawActionPayloadVersion != null &&
            rawActionPayloadVersion != 1 &&
            rawActionPayloadVersion != '1' &&
            rawActionPayloadVersion != 2 &&
            rawActionPayloadVersion != '2') ||
        (actionPayloadVersion == 2 &&
            (provider != 'codex' ||
                bridgeInstanceId == null ||
                codexSourceId == null ||
                threadId == null ||
                turnId == null ||
                authorityGeneration == null ||
                allowedActions == null ||
                !(allowedActions.contains('approve') ||
                    allowedActions.contains('reject'))))) {
      return null;
    }
    return NotificationApprovalActionEvent(
      actionId: actionId!,
      sessionId: sessionId,
      provider: provider!,
      providerSessionId: providerSessionId,
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: codexSourceId,
      bridgeRouteIdentity: bridgeRouteIdentity,
      permissionId: permissionId,
      occurredAt: occurredAt,
      actionPayloadVersion: actionPayloadVersion,
      threadId: threadId,
      turnId: turnId,
      authorityGeneration: authorityGeneration,
      allowedActions: allowedActions ?? const <String>{},
    );
  }
}

Set<String>? _boundedActionSet(Object? value) {
  final raw = switch (value) {
    String text => text.split(','),
    List values => values,
    _ => null,
  };
  if (raw == null || raw.length > 4) return null;
  final actions = <String>{};
  for (final item in raw) {
    if (item is! String) return null;
    final action = item.trim();
    if (!const {
      'approve',
      'approve_always',
      'reject',
      'answer',
    }.contains(action)) {
      return null;
    }
    actions.add(action);
  }
  return actions.isEmpty ? null : Set.unmodifiable(actions);
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
