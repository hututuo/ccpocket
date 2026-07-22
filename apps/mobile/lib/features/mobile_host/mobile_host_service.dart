import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const mobileHostChannelName = 'ccpocket/mobile_host';
const mobileHostSnapshotSchemaVersion = 1;
const mobileHostProbeTimeout = Duration(seconds: 2);

/// Native capabilities that an OTA patch may consume from the installed IPA.
///
/// The string identifiers are part of the App/Bridge compatibility contract.
enum MobileHostCapability {
  permissionHost('permissionHost'),
  fileTransfer('fileTransfer'),
  quickLook('quickLook'),
  share('share'),
  notifications('notifications'),
  speech('speech'),
  webView('webView'),
  secureStorage('secureStorage'),
  database('database'),
  clipboard('clipboard'),
  dragDrop('dragDrop');

  const MobileHostCapability(this.id);

  final String id;
}

@immutable
class MobileHostSnapshot {
  const MobileHostSnapshot({
    required this.supported,
    required this.schemaVersion,
    required this.capabilities,
    this.platform,
    this.baseVersion,
    this.buildNumber,
    this.reason,
  });

  const MobileHostSnapshot.unavailable(this.reason)
    : supported = false,
      schemaVersion = 0,
      capabilities = const {},
      platform = null,
      baseVersion = null,
      buildNumber = null;

  final bool supported;
  final int schemaVersion;
  final Map<String, int> capabilities;
  final String? platform;
  final String? baseVersion;
  final String? buildNumber;
  final String? reason;

  bool supports(MobileHostCapability capability, {int minimumVersion = 1}) {
    return supported &&
        schemaVersion >= mobileHostSnapshotSchemaVersion &&
        (capabilities[capability.id] ?? 0) >= minimumVersion;
  }

  Map<String, dynamic> toClientCapabilitiesJson({int? patchNumber}) {
    return <String, dynamic>{
      if (baseVersion != null) 'baseVersion': baseVersion,
      if (buildNumber != null) 'buildNumber': buildNumber,
      'patchNumber': ?patchNumber,
      'hostSchemaVersion': schemaVersion,
      'nativeCapabilities': capabilities,
    };
  }

  static MobileHostSnapshot fromChannelValue(Map<Object?, Object?>? value) {
    if (value == null) {
      return const MobileHostSnapshot.unavailable('invalid_snapshot_response');
    }
    final supported = value['supported'];
    final schemaVersion = value['schemaVersion'];
    final capabilities = value['capabilities'];
    final platform = value['platform'];
    final baseVersion = value['baseVersion'];
    final buildNumber = value['buildNumber'];
    final reason = value['reason'];
    if (supported is! bool ||
        schemaVersion is! int ||
        schemaVersion < 0 ||
        schemaVersion > 1000 ||
        capabilities is! Map ||
        (platform != null && platform is! String) ||
        (baseVersion != null &&
            (baseVersion is! String || baseVersion.length > 64)) ||
        (buildNumber != null &&
            (buildNumber is! String || buildNumber.length > 64)) ||
        (reason != null && reason is! String)) {
      return const MobileHostSnapshot.unavailable('invalid_snapshot_response');
    }

    final parsedCapabilities = <String, int>{};
    if (capabilities.length > 64) {
      return const MobileHostSnapshot.unavailable('invalid_snapshot_response');
    }
    for (final entry in capabilities.entries) {
      final key = entry.key;
      final version = entry.value;
      if (key is! String ||
          version is! int ||
          version < 1 ||
          version > 1000 ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$').hasMatch(key)) {
        return const MobileHostSnapshot.unavailable(
          'invalid_snapshot_response',
        );
      }
      parsedCapabilities[key] = version;
    }
    if (!supported) {
      return MobileHostSnapshot.unavailable(
        reason as String? ?? 'native_host_unsupported',
      );
    }
    if (schemaVersion < mobileHostSnapshotSchemaVersion) {
      return const MobileHostSnapshot.unavailable('host_schema_unsupported');
    }

    return MobileHostSnapshot(
      supported: true,
      schemaVersion: schemaVersion,
      capabilities: Map.unmodifiable(parsedCapabilities),
      platform: platform as String?,
      baseVersion: baseVersion as String?,
      buildNumber: buildNumber as String?,
      reason: reason as String?,
    );
  }
}

abstract interface class MobileHostGateway {
  Future<MobileHostSnapshot> getSnapshot();
}

class MethodChannelMobileHostGateway implements MobileHostGateway {
  const MethodChannelMobileHostGateway([
    this._channel = const MethodChannel(mobileHostChannelName),
  ]);

  final MethodChannel _channel;

  @override
  Future<MobileHostSnapshot> getSnapshot() async {
    try {
      final value = await _channel
          .invokeMapMethod<Object?, Object?>('getSnapshot')
          .timeout(mobileHostProbeTimeout);
      return MobileHostSnapshot.fromChannelValue(value);
    } on MissingPluginException {
      return const MobileHostSnapshot.unavailable('native_plugin_missing');
    } on PlatformException catch (error) {
      return MobileHostSnapshot.unavailable('platform_error:${error.code}');
    } on TimeoutException {
      return const MobileHostSnapshot.unavailable('snapshot_timeout');
    }
  }
}

class MobileHostService {
  MobileHostService({MobileHostGateway? gateway})
    : _gateway = gateway ?? const MethodChannelMobileHostGateway();

  final MobileHostGateway _gateway;
  MobileHostSnapshot? _cachedSnapshot;

  MobileHostSnapshot? get cachedSnapshot => _cachedSnapshot;

  Future<MobileHostSnapshot> loadSnapshot({bool force = false}) async {
    if (!force) {
      final snapshot = _cachedSnapshot;
      if (snapshot != null) return snapshot;
    }
    final snapshot = await _gateway.getSnapshot();
    _cachedSnapshot = snapshot;
    return snapshot;
  }

  Future<bool> supports(
    MobileHostCapability capability, {
    int minimumVersion = 1,
  }) async {
    final snapshot = await loadSnapshot();
    return snapshot.supports(capability, minimumVersion: minimumVersion);
  }
}
