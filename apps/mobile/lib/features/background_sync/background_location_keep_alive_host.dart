import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Public constructor labels are part of the host boundary; initializing
// formals would expose private field names to callers.
// ignore_for_file: prefer_initializing_formals

const backgroundLocationKeepAliveChannelName =
    'ccpocket/background_location_keep_alive';
const backgroundLocationKeepAliveNativeApiVersion = 1;

enum BackgroundLocationAuthorization {
  notDetermined,
  restricted,
  denied,
  authorizedWhenInUse,
  authorizedAlways,
  unknown,
}

@immutable
class BackgroundLocationKeepAliveSnapshot {
  const BackgroundLocationKeepAliveSnapshot({
    required this.supported,
    required this.nativeApiVersion,
    required this.authorization,
    required this.active,
    required this.lowPowerModeEnabled,
    required this.thermalState,
    this.pauseReason,
  });

  const BackgroundLocationKeepAliveSnapshot.unavailable(this.pauseReason)
    : supported = false,
      nativeApiVersion = 0,
      authorization = BackgroundLocationAuthorization.unknown,
      active = false,
      lowPowerModeEnabled = false,
      thermalState = 'unknown';

  final bool supported;
  final int nativeApiVersion;
  final BackgroundLocationAuthorization authorization;
  final bool active;
  final bool lowPowerModeEnabled;
  final String thermalState;
  final String? pauseReason;

  bool get hasAlwaysAuthorization =>
      authorization == BackgroundLocationAuthorization.authorizedAlways;
}

abstract interface class BackgroundLocationKeepAliveHost {
  bool get supportsKeepAlive;
  Stream<BackgroundLocationKeepAliveSnapshot> get statusChanges;

  Future<BackgroundLocationKeepAliveSnapshot> getSnapshot();
  Future<BackgroundLocationKeepAliveSnapshot> start();
  Future<BackgroundLocationKeepAliveSnapshot> stop();
  Future<void> dispose();
}

class MethodChannelBackgroundLocationKeepAliveHost
    implements BackgroundLocationKeepAliveHost {
  MethodChannelBackgroundLocationKeepAliveHost({
    required bool supportedByInstalledHost,
    MethodChannel channel = const MethodChannel(
      backgroundLocationKeepAliveChannelName,
    ),
  }) : _supportedByInstalledHost = supportedByInstalledHost,
       _channel = channel {
    _channel.setMethodCallHandler(_handleNativeMethod);
  }

  final bool _supportedByInstalledHost;
  final MethodChannel _channel;
  final _statusController =
      StreamController<BackgroundLocationKeepAliveSnapshot>.broadcast();

  @override
  bool get supportsKeepAlive => _supportedByInstalledHost;

  @override
  Stream<BackgroundLocationKeepAliveSnapshot> get statusChanges =>
      _statusController.stream;

  @override
  Future<BackgroundLocationKeepAliveSnapshot> getSnapshot() =>
      _invoke('getSnapshot');

  @override
  Future<BackgroundLocationKeepAliveSnapshot> start() => _invoke('start');

  @override
  Future<BackgroundLocationKeepAliveSnapshot> stop() => _invoke('stop');

  Future<BackgroundLocationKeepAliveSnapshot> _invoke(String method) async {
    if (!_supportedByInstalledHost) {
      return const BackgroundLocationKeepAliveSnapshot.unavailable(
        'base_app_update_required',
      );
    }
    try {
      final value = await _channel
          .invokeMapMethod<Object?, Object?>(method)
          .timeout(const Duration(seconds: 3));
      return _parseSnapshot(value);
    } on MissingPluginException {
      return const BackgroundLocationKeepAliveSnapshot.unavailable(
        'native_plugin_missing',
      );
    } on PlatformException catch (error) {
      return BackgroundLocationKeepAliveSnapshot.unavailable(
        'platform_error:${error.code}',
      );
    } on TimeoutException {
      return BackgroundLocationKeepAliveSnapshot.unavailable(
        '${method}_timeout',
      );
    }
  }

  Future<void> _handleNativeMethod(MethodCall call) async {
    if (call.method != 'statusChanged' || call.arguments is! Map) return;
    final value = Map<Object?, Object?>.from(call.arguments as Map);
    _statusController.add(_parseSnapshot(value));
  }

  static BackgroundLocationKeepAliveSnapshot _parseSnapshot(
    Map<Object?, Object?>? value,
  ) {
    if (value == null) {
      return const BackgroundLocationKeepAliveSnapshot.unavailable(
        'invalid_snapshot_response',
      );
    }
    final supported = value['supported'];
    final nativeApiVersion = value['nativeApiVersion'];
    final authorization = value['authorization'];
    final active = value['active'];
    final lowPowerModeEnabled = value['lowPowerModeEnabled'];
    final thermalState = value['thermalState'];
    final pauseReason = value['pauseReason'];
    if (supported is! bool ||
        nativeApiVersion is! int ||
        authorization is! String ||
        active is! bool ||
        lowPowerModeEnabled is! bool ||
        thermalState is! String ||
        (pauseReason != null && pauseReason is! String)) {
      return const BackgroundLocationKeepAliveSnapshot.unavailable(
        'invalid_snapshot_response',
      );
    }
    if (!supported ||
        nativeApiVersion < backgroundLocationKeepAliveNativeApiVersion) {
      return BackgroundLocationKeepAliveSnapshot.unavailable(
        !supported ? 'native_host_unsupported' : 'native_api_unsupported',
      );
    }
    return BackgroundLocationKeepAliveSnapshot(
      supported: true,
      nativeApiVersion: nativeApiVersion,
      authorization: _authorizationFromRaw(authorization),
      active: active,
      lowPowerModeEnabled: lowPowerModeEnabled,
      thermalState: thermalState,
      pauseReason: pauseReason as String?,
    );
  }

  static BackgroundLocationAuthorization _authorizationFromRaw(String value) {
    return switch (value) {
      'notDetermined' => BackgroundLocationAuthorization.notDetermined,
      'restricted' => BackgroundLocationAuthorization.restricted,
      'denied' => BackgroundLocationAuthorization.denied,
      'authorizedWhenInUse' =>
        BackgroundLocationAuthorization.authorizedWhenInUse,
      'authorizedAlways' => BackgroundLocationAuthorization.authorizedAlways,
      _ => BackgroundLocationAuthorization.unknown,
    };
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _statusController.close();
  }
}
