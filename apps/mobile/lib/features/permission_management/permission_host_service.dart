import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const permissionHostChannelName = 'ccpocket/permission_host';
const permissionHostNativeApiVersion = 2;
const permissionHostProbeTimeout = Duration(seconds: 2);
const permissionHostRequestTimeout = Duration(minutes: 2);

/// Permission identifiers accepted by the pre-installed mobile host.
///
/// Bridge-provided capability manifests may refer to these stable identifiers,
/// but only an explicit user action in the app may call
/// [PermissionHostService.requestFromUserAction]. Unknown identifiers fail
/// closed so a newer Bridge cannot silently expand an older app's authority.
enum MobilePermission {
  notifications('notifications'),
  camera('camera'),
  photoLibrary('photoLibrary'),
  microphone('microphone'),
  speechRecognition('speechRecognition'),
  localNetwork('localNetwork'),
  files('files'),
  biometrics('biometrics');

  const MobilePermission(this.id);

  final String id;

  static MobilePermission? fromId(String id) {
    for (final permission in values) {
      if (permission.id == id) return permission;
    }
    return null;
  }
}

enum MobilePermissionStatus {
  notDetermined,
  authorized,
  denied,
  restricted,
  limited,
  provisional,
  ephemeral,
  systemManaged,
  unavailable,
  unknown,
}

enum MobilePermissionRequestMode {
  none,
  direct,
  openSettings,
  featureTriggered,
  systemPicker,
  unavailable,
}

class MobilePermissionState {
  const MobilePermissionState({
    required this.permission,
    required this.status,
    required this.requestMode,
  });

  final MobilePermission permission;
  final MobilePermissionStatus status;
  final MobilePermissionRequestMode requestMode;

  bool get isGranted => switch (status) {
    MobilePermissionStatus.authorized ||
    MobilePermissionStatus.limited ||
    MobilePermissionStatus.provisional ||
    MobilePermissionStatus.ephemeral => true,
    _ => false,
  };
}

class PermissionHostSnapshot {
  const PermissionHostSnapshot({
    required this.supported,
    required this.nativeApiVersion,
    required this.permissions,
    this.reason,
    this.appVersion,
    this.buildNumber,
  });

  const PermissionHostSnapshot.unavailable(this.reason)
    : supported = false,
      nativeApiVersion = 0,
      permissions = const {},
      appVersion = null,
      buildNumber = null;

  final bool supported;
  final int nativeApiVersion;
  final Map<MobilePermission, MobilePermissionState> permissions;
  final String? reason;
  final String? appVersion;
  final String? buildNumber;

  MobilePermissionState stateFor(MobilePermission permission) {
    return permissions[permission] ??
        MobilePermissionState(
          permission: permission,
          status: MobilePermissionStatus.unavailable,
          requestMode: MobilePermissionRequestMode.unavailable,
        );
  }
}

enum PermissionRequirementDisposition {
  satisfied,
  requestable,
  blocked,
  featureManaged,
  requiresAppUpdate,
}

class PermissionRequirementCheck {
  const PermissionRequirementCheck(this.requirements);

  final Map<String, PermissionRequirementDisposition> requirements;

  bool get allSatisfied => requirements.values.every(
    (value) => value == PermissionRequirementDisposition.satisfied,
  );

  bool get requiresAppUpdate => requirements.values.contains(
    PermissionRequirementDisposition.requiresAppUpdate,
  );
}

abstract interface class PermissionHostGateway {
  Future<PermissionHostSnapshot> getSnapshot();

  Future<PermissionHostSnapshot> requestPermission(MobilePermission permission);

  Future<bool> openAppSettings();
}

class MethodChannelPermissionHostGateway implements PermissionHostGateway {
  const MethodChannelPermissionHostGateway([
    this._channel = const MethodChannel(permissionHostChannelName),
  ]);

  final MethodChannel _channel;

  @override
  Future<PermissionHostSnapshot> getSnapshot() async {
    try {
      final value = await _channel
          .invokeMapMethod<Object?, Object?>('getSnapshot')
          .timeout(permissionHostProbeTimeout);
      return _parseSnapshot(value);
    } on MissingPluginException {
      return const PermissionHostSnapshot.unavailable('native_plugin_missing');
    } on PlatformException catch (error) {
      return PermissionHostSnapshot.unavailable('platform_error:${error.code}');
    } on TimeoutException {
      return const PermissionHostSnapshot.unavailable('snapshot_timeout');
    }
  }

  @override
  Future<PermissionHostSnapshot> requestPermission(
    MobilePermission permission,
  ) async {
    try {
      final value = await _channel
          .invokeMapMethod<Object?, Object?>('requestPermission', {
            'permissionId': permission.id,
          })
          .timeout(permissionHostRequestTimeout);
      return _parseSnapshot(value);
    } on MissingPluginException {
      return const PermissionHostSnapshot.unavailable('native_plugin_missing');
    } on PlatformException catch (error) {
      return PermissionHostSnapshot.unavailable('platform_error:${error.code}');
    } on TimeoutException {
      return const PermissionHostSnapshot.unavailable('request_timeout');
    }
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await _channel
              .invokeMethod<bool>('openAppSettings')
              .timeout(permissionHostProbeTimeout) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('Permission settings unavailable: ${error.code}');
      return false;
    } on TimeoutException {
      return false;
    }
  }

  static PermissionHostSnapshot _parseSnapshot(Map<Object?, Object?>? value) {
    if (value == null) {
      return const PermissionHostSnapshot.unavailable(
        'invalid_snapshot_response',
      );
    }
    final supported = value['supported'];
    final nativeApiVersion = value['nativeApiVersion'];
    final rawPermissions = value['permissions'];
    final reason = value['reason'];
    final appVersion = value['appVersion'];
    final buildNumber = value['buildNumber'];
    if (supported is! bool ||
        nativeApiVersion is! int ||
        rawPermissions is! Map ||
        (reason != null && reason is! String) ||
        (appVersion != null && appVersion is! String) ||
        (buildNumber != null && buildNumber is! String)) {
      return const PermissionHostSnapshot.unavailable(
        'invalid_snapshot_response',
      );
    }
    if (!supported || nativeApiVersion < permissionHostNativeApiVersion) {
      return PermissionHostSnapshot.unavailable(
        !supported ? 'native_host_unsupported' : 'native_api_unsupported',
      );
    }

    final parsed = <MobilePermission, MobilePermissionState>{};
    for (final permission in MobilePermission.values) {
      final rawState = rawPermissions[permission.id];
      if (rawState is! Map) continue;
      final status = rawState['status'];
      final requestMode = rawState['requestMode'];
      if (status is! String || requestMode is! String) continue;
      parsed[permission] = MobilePermissionState(
        permission: permission,
        status: _statusFromRaw(status),
        requestMode: _requestModeFromRaw(requestMode),
      );
    }

    return PermissionHostSnapshot(
      supported: true,
      nativeApiVersion: nativeApiVersion,
      permissions: Map.unmodifiable(parsed),
      reason: reason as String?,
      appVersion: appVersion as String?,
      buildNumber: buildNumber as String?,
    );
  }

  static MobilePermissionStatus _statusFromRaw(String raw) => switch (raw) {
    'notDetermined' => MobilePermissionStatus.notDetermined,
    'authorized' => MobilePermissionStatus.authorized,
    'denied' => MobilePermissionStatus.denied,
    'restricted' => MobilePermissionStatus.restricted,
    'limited' => MobilePermissionStatus.limited,
    'provisional' => MobilePermissionStatus.provisional,
    'ephemeral' => MobilePermissionStatus.ephemeral,
    'systemManaged' => MobilePermissionStatus.systemManaged,
    'unavailable' => MobilePermissionStatus.unavailable,
    _ => MobilePermissionStatus.unknown,
  };

  static MobilePermissionRequestMode _requestModeFromRaw(String raw) =>
      switch (raw) {
        'none' => MobilePermissionRequestMode.none,
        'direct' => MobilePermissionRequestMode.direct,
        'openSettings' => MobilePermissionRequestMode.openSettings,
        'featureTriggered' => MobilePermissionRequestMode.featureTriggered,
        'systemPicker' => MobilePermissionRequestMode.systemPicker,
        _ => MobilePermissionRequestMode.unavailable,
      };
}

class PermissionHostService {
  PermissionHostService._({PermissionHostGateway? gateway})
    : _gateway = gateway ?? const MethodChannelPermissionHostGateway();

  static final instance = PermissionHostService._();

  @visibleForTesting
  factory PermissionHostService.test({required PermissionHostGateway gateway}) {
    return PermissionHostService._(gateway: gateway);
  }

  final PermissionHostGateway _gateway;

  Future<PermissionHostSnapshot> getSnapshot() => _gateway.getSnapshot();

  /// Requests one permission after a deliberate user action.
  ///
  /// The declarative capability host must never call this while rendering a
  /// manifest or processing a background Bridge event.
  Future<PermissionHostSnapshot> requestFromUserAction(
    MobilePermission permission,
  ) => _gateway.requestPermission(permission);

  Future<bool> openAppSettings() => _gateway.openAppSettings();

  Future<PermissionRequirementCheck> checkRequirements(
    Iterable<String> permissionIds,
  ) async {
    final snapshot = await getSnapshot();
    final result = <String, PermissionRequirementDisposition>{};
    for (final id in permissionIds.toSet()) {
      final permission = MobilePermission.fromId(id);
      if (permission == null || !snapshot.supported) {
        result[id] = PermissionRequirementDisposition.requiresAppUpdate;
        continue;
      }
      result[id] = _dispositionFor(snapshot.stateFor(permission));
    }
    return PermissionRequirementCheck(Map.unmodifiable(result));
  }

  static PermissionRequirementDisposition _dispositionFor(
    MobilePermissionState state,
  ) {
    if (state.isGranted) return PermissionRequirementDisposition.satisfied;
    return switch (state.requestMode) {
      MobilePermissionRequestMode.direct =>
        PermissionRequirementDisposition.requestable,
      MobilePermissionRequestMode.openSettings =>
        PermissionRequirementDisposition.blocked,
      MobilePermissionRequestMode.featureTriggered ||
      MobilePermissionRequestMode.systemPicker =>
        PermissionRequirementDisposition.featureManaged,
      MobilePermissionRequestMode.none ||
      MobilePermissionRequestMode.unavailable =>
        PermissionRequirementDisposition.requiresAppUpdate,
    };
  }
}
