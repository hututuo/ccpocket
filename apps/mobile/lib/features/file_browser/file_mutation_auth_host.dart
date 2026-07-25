import 'package:flutter/services.dart';

const fileMutationAuthChannelName = 'ccpocket/file_mutation_auth';
const fileMutationAuthNativeApiVersion = 1;

abstract interface class FileMutationAuthNativeGateway {
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]);
}

class MethodChannelFileMutationAuthGateway
    implements FileMutationAuthNativeGateway {
  const MethodChannelFileMutationAuthGateway([
    this.channel = const MethodChannel(fileMutationAuthChannelName),
  ]);

  final MethodChannel channel;

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      channel.invokeMethod<Object?>(method, arguments);
}

class FileMutationBiometricSnapshot {
  const FileMutationBiometricSnapshot({
    required this.supported,
    required this.canEvaluateBiometrics,
    required this.keyPrepared,
    required this.deviceId,
    required this.biometryType,
    this.reason,
  });

  const FileMutationBiometricSnapshot.unavailable(this.reason)
    : supported = false,
      canEvaluateBiometrics = false,
      keyPrepared = false,
      deviceId = '',
      biometryType = 'none';

  final bool supported;
  final bool canEvaluateBiometrics;
  final bool keyPrepared;
  final String deviceId;
  final String biometryType;
  final String? reason;

  bool get canSign => supported && canEvaluateBiometrics && keyPrepared;
}

class FileMutationBiometricKey {
  const FileMutationBiometricKey({
    required this.deviceId,
    required this.publicKey,
    required this.biometryType,
  });

  final String deviceId;
  final String publicKey;
  final String biometryType;
}

class FileMutationBiometricSignature {
  const FileMutationBiometricSignature({
    required this.deviceId,
    required this.signature,
  });

  final String deviceId;
  final String signature;
}

class FileMutationBiometricHost {
  const FileMutationBiometricHost({
    required this.supportedByInstalledHost,
    FileMutationAuthNativeGateway? gateway,
  }) : _gateway = gateway ?? const MethodChannelFileMutationAuthGateway();

  final bool supportedByInstalledHost;
  final FileMutationAuthNativeGateway _gateway;

  Future<FileMutationBiometricSnapshot> snapshot() async {
    if (!supportedByInstalledHost) {
      return const FileMutationBiometricSnapshot.unavailable(
        'base_ipa_update_required',
      );
    }
    try {
      final value = await _gateway.invoke('getSnapshot');
      final json = _boundedMap(value);
      final supported =
          json['supported'] == true &&
          json['nativeApiVersion'] == fileMutationAuthNativeApiVersion;
      final deviceId = _boundedText(json['deviceId'], 128);
      final biometryType = _boundedText(json['biometryType'], 32);
      if (!supported || deviceId == null || biometryType == null) {
        return const FileMutationBiometricSnapshot.unavailable(
          'invalid_native_snapshot',
        );
      }
      return FileMutationBiometricSnapshot(
        supported: true,
        canEvaluateBiometrics: json['canEvaluateBiometrics'] == true,
        keyPrepared: json['keyPrepared'] == true,
        deviceId: deviceId,
        biometryType: biometryType,
        reason: _boundedText(json['reason'], 240),
      );
    } on MissingPluginException {
      return const FileMutationBiometricSnapshot.unavailable(
        'base_ipa_update_required',
      );
    } on PlatformException catch (error) {
      return FileMutationBiometricSnapshot.unavailable(error.code);
    } on FormatException {
      return const FileMutationBiometricSnapshot.unavailable(
        'invalid_native_snapshot',
      );
    }
  }

  Future<FileMutationBiometricKey> prepareKey() async {
    if (!supportedByInstalledHost) {
      throw const FileMutationBiometricException('base_ipa_update_required');
    }
    try {
      final json = _boundedMap(await _gateway.invoke('prepareKey'));
      final deviceId = _boundedText(json['deviceId'], 128);
      final publicKey = _boundedText(json['publicKey'], 256);
      final biometryType = _boundedText(json['biometryType'], 32);
      if (deviceId == null || publicKey == null || biometryType == null) {
        throw const FileMutationBiometricException('invalid_native_response');
      }
      return FileMutationBiometricKey(
        deviceId: deviceId,
        publicKey: publicKey,
        biometryType: biometryType,
      );
    } on PlatformException catch (error) {
      throw FileMutationBiometricException(error.code);
    } on MissingPluginException {
      throw const FileMutationBiometricException('base_ipa_update_required');
    }
  }

  Future<FileMutationBiometricSignature> sign(
    String payload, {
    required String reason,
  }) async {
    if (!supportedByInstalledHost ||
        payload.isEmpty ||
        payload.length > 4096 ||
        reason.isEmpty) {
      throw const FileMutationBiometricException('invalid_challenge');
    }
    try {
      final json = _boundedMap(
        await _gateway.invoke('signChallenge', {
          'payload': payload,
          'reason': reason.length > 160 ? reason.substring(0, 160) : reason,
        }),
      );
      final deviceId = _boundedText(json['deviceId'], 128);
      final signature = _boundedText(json['signature'], 256);
      if (deviceId == null || signature == null) {
        throw const FileMutationBiometricException('invalid_native_response');
      }
      return FileMutationBiometricSignature(
        deviceId: deviceId,
        signature: signature,
      );
    } on PlatformException catch (error) {
      throw FileMutationBiometricException(error.code);
    } on MissingPluginException {
      throw const FileMutationBiometricException('base_ipa_update_required');
    }
  }
}

class FileMutationBiometricException implements Exception {
  const FileMutationBiometricException(this.code);

  final String code;

  @override
  String toString() => code;
}

Map<Object?, Object?> _boundedMap(Object? value) {
  if (value is! Map || value.length > 16) {
    throw const FormatException('invalid native file mutation response');
  }
  return value;
}

String? _boundedText(Object? value, int maxLength) {
  if (value == null) return null;
  return value is String && value.isNotEmpty && value.length <= maxLength
      ? value
      : null;
}
