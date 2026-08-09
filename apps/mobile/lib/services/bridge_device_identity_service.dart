import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../utils/network_endpoint.dart';

const bridgeIdentityV3Capability = 'bridge_identity_v3';

String _base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _decodeBase64Url(String value) {
  final normalized = value.trim();
  final padding = (4 - normalized.length % 4) % 4;
  return base64Url.decode(
    '$normalized${List<String>.filled(padding, '=').join()}',
  );
}

String _boundedRequiredString(
  Object? value, {
  required String field,
  required int maxLength,
}) {
  if (value is! String) {
    throw const FormatException('Bridge identity document is incomplete.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw FormatException('Invalid Bridge identity field: $field.');
  }
  return normalized;
}

String? _boundedOptionalString(Object? value, {required int maxLength}) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('Bridge identity document is malformed.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  if (normalized.length > maxLength) {
    throw const FormatException('Bridge identity field is too long.');
  }
  return normalized;
}

/// Public, self-signed identity returned by a modern Bridge.
///
/// It proves that multiple routes own the same Bridge signing key. Trust for
/// privileged operations is established separately through device pairing or
/// the legacy API-key fallback.
class BridgeIdentityDocument {
  const BridgeIdentityDocument({
    required this.version,
    required this.bridgeIdentityId,
    required this.publicKey,
    required this.bridgeInstanceId,
    required this.computerName,
    required this.nonce,
    required this.authMode,
    required this.methods,
    required this.signature,
    required this.signedPayload,
  });

  final int version;
  final String bridgeIdentityId;
  final String publicKey;
  final String bridgeInstanceId;
  final String computerName;
  final String nonce;
  final String authMode;
  final List<String> methods;
  final String signature;

  /// Exact UTF-8 payload signed by the Bridge.
  ///
  /// Carrying it explicitly avoids cross-language JSON canonicalization drift.
  /// Every field above is still checked against the decoded payload before it
  /// is accepted.
  final String signedPayload;

  factory BridgeIdentityDocument.fromJson(
    Map<String, dynamic> json, {
    required String expectedNonce,
  }) {
    final version = json['version'];
    if (version is! int || version != 1) {
      throw const FormatException('Unsupported Bridge identity version.');
    }
    final methodsRaw = json['methods'];
    if (methodsRaw is! List || methodsRaw.length > 16) {
      throw const FormatException('Invalid Bridge authentication methods.');
    }
    final methods = methodsRaw
        .map(
          (value) =>
              _boundedRequiredString(value, field: 'methods', maxLength: 64),
        )
        .toList(growable: false);
    final document = BridgeIdentityDocument(
      version: version,
      bridgeIdentityId: _boundedRequiredString(
        json['bridgeIdentityId'],
        field: 'bridgeIdentityId',
        maxLength: 128,
      ),
      publicKey: _boundedRequiredString(
        json['publicKey'],
        field: 'publicKey',
        maxLength: 128,
      ),
      bridgeInstanceId: _boundedRequiredString(
        json['bridgeInstanceId'],
        field: 'bridgeInstanceId',
        maxLength: 256,
      ),
      computerName: _boundedRequiredString(
        json['computerName'],
        field: 'computerName',
        maxLength: 256,
      ),
      nonce: _boundedRequiredString(
        json['nonce'],
        field: 'nonce',
        maxLength: 256,
      ),
      authMode: _boundedRequiredString(
        json['authMode'],
        field: 'authMode',
        maxLength: 64,
      ),
      methods: methods,
      signature: _boundedRequiredString(
        json['signature'],
        field: 'signature',
        maxLength: 256,
      ),
      signedPayload: _boundedRequiredString(
        json['signedPayload'],
        field: 'signedPayload',
        maxLength: 4096,
      ),
    );
    if (document.nonce != expectedNonce) {
      throw const FormatException('Bridge identity nonce mismatch.');
    }
    if (document.computerName.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(document.computerName)) {
      throw const FormatException('Bridge computer name is invalid.');
    }
    document._validateSignedPayload();
    return document;
  }

  void _validateSignedPayload() {
    final decoded = jsonDecode(signedPayload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Bridge identity payload is malformed.');
    }
    final payloadMethods = decoded['methods'];
    if (decoded['version'] != version ||
        decoded['bridgeIdentityId'] != bridgeIdentityId ||
        decoded['publicKey'] != publicKey ||
        decoded['bridgeInstanceId'] != bridgeInstanceId ||
        decoded['computerName'] != computerName ||
        decoded['nonce'] != nonce ||
        decoded['authMode'] != authMode ||
        payloadMethods is! List ||
        payloadMethods.length != methods.length) {
      throw const FormatException('Bridge identity payload does not match.');
    }
    for (var index = 0; index < methods.length; index++) {
      if (payloadMethods[index] != methods[index]) {
        throw const FormatException('Bridge identity methods do not match.');
      }
    }
  }
}

class BridgeIdentityProbeResult {
  const BridgeIdentityProbeResult({
    required this.document,
    required this.latencyMs,
  });

  /// Null means a legacy Bridge explicitly returned 404 for the identity API.
  final BridgeIdentityDocument? document;
  final int latencyMs;
}

/// Probes and verifies the public Bridge identity endpoint.
class BridgeIdentityProbe {
  BridgeIdentityProbe({http.Client? client, Random? random})
    : _client = client ?? http.Client(),
      _random = random ?? Random.secure(),
      _ownsClient = client == null;

  final http.Client _client;
  final Random _random;
  final bool _ownsClient;
  final Ed25519 _ed25519 = Ed25519();

  Future<BridgeIdentityProbeResult> probe(
    String httpBaseUrl, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final nonceBytes = List<int>.generate(24, (_) => _random.nextInt(256));
    final nonce = _base64UrlNoPadding(nonceBytes);
    final base = Uri.parse(httpBaseUrl);
    final identityUri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/bridge/identity',
      queryParameters: {'nonce': nonce},
    );
    final stopwatch = Stopwatch()..start();
    final response = await _client.get(identityUri).timeout(timeout);
    stopwatch.stop();
    if (response.statusCode == 404) {
      return BridgeIdentityProbeResult(
        document: null,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Bridge identity endpoint returned HTTP ${response.statusCode}.',
        identityUri,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Bridge identity response is malformed.');
    }
    final document = BridgeIdentityDocument.fromJson(
      decoded,
      expectedNonce: nonce,
    );
    final publicKeyBytes = _decodeBase64Url(document.publicKey);
    final signatureBytes = _decodeBase64Url(document.signature);
    if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
      throw const FormatException('Bridge identity key material is invalid.');
    }
    final expectedIdentity =
        'bridge_${_base64UrlNoPadding((await Sha256().hash(publicKeyBytes)).bytes)}';
    if (document.bridgeIdentityId != expectedIdentity) {
      throw const FormatException('Bridge identity fingerprint mismatch.');
    }
    final verified = await _ed25519.verify(
      utf8.encode(document.signedPayload),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!verified) {
      throw const FormatException('Bridge identity signature is invalid.');
    }
    return BridgeIdentityProbeResult(
      document: document,
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class BridgeDeviceCredential {
  const BridgeDeviceCredential({
    required this.deviceId,
    required this.publicKey,
    required this.privateSeed,
  });

  final String deviceId;
  final String publicKey;
  final List<int> privateSeed;
}

class BridgeDeviceProof {
  const BridgeDeviceProof({
    required this.deviceId,
    required this.publicKey,
    required this.signature,
  });

  final String deviceId;
  final String publicKey;
  final String signature;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'publicKey': publicKey,
    'signature': signature,
  };
}

/// Owns the phone's long-lived pairing key.
///
/// This key is used for seamless Bridge authentication and is intentionally
/// separate from the Secure Enclave / Face ID key that authorizes individual
/// file mutations.
class BridgeDeviceIdentityService {
  BridgeDeviceIdentityService(this._storage);

  static const _seedKey = 'bridge_device_identity_v1_seed';
  static const _publicKeyKey = 'bridge_device_identity_v1_public';
  static const _deviceIdKey = 'bridge_device_identity_v1_id';

  final FlutterSecureStorage _storage;
  final Ed25519 _ed25519 = Ed25519();
  Future<BridgeDeviceCredential>? _credentialFuture;

  Future<BridgeDeviceCredential> loadOrCreate() =>
      _credentialFuture ??= _loadOrCreate();

  Future<BridgeDeviceCredential> _loadOrCreate() async {
    final storedSeed = await _storage.read(key: _seedKey);
    final storedPublic = await _storage.read(key: _publicKeyKey);
    final storedDeviceId = await _storage.read(key: _deviceIdKey);
    final hasStoredCredential =
        storedSeed != null || storedPublic != null || storedDeviceId != null;
    if (hasStoredCredential) {
      if (storedSeed == null ||
          storedPublic == null ||
          storedDeviceId == null) {
        throw StateError('Bridge device identity is incomplete.');
      }
      try {
        final seed = _decodeBase64Url(storedSeed);
        final publicKey = _decodeBase64Url(storedPublic);
        if (seed.length == 32 && publicKey.length == 32) {
          final keyPair = await _ed25519.newKeyPairFromSeed(seed);
          final derived = await keyPair.extractPublicKey();
          if (_base64UrlNoPadding(derived.bytes) == storedPublic &&
              await _deviceIdFor(derived.bytes) == storedDeviceId) {
            return BridgeDeviceCredential(
              deviceId: storedDeviceId,
              publicKey: storedPublic,
              privateSeed: seed,
            );
          }
        }
      } on FormatException catch (error) {
        throw StateError('Bridge device identity is malformed: $error');
      }
      throw StateError('Bridge device identity key material does not match.');
    }

    final keyPair = await _ed25519.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyText = _base64UrlNoPadding(publicKey.bytes);
    final deviceId = await _deviceIdFor(publicKey.bytes);
    await _storage.write(key: _seedKey, value: _base64UrlNoPadding(seed));
    await _storage.write(key: _publicKeyKey, value: publicKeyText);
    await _storage.write(key: _deviceIdKey, value: deviceId);
    return BridgeDeviceCredential(
      deviceId: deviceId,
      publicKey: publicKeyText,
      privateSeed: seed,
    );
  }

  Future<String> _deviceIdFor(List<int> publicKey) async {
    final digest = await Sha256().hash(publicKey);
    return 'device_${_base64UrlNoPadding(digest.bytes)}';
  }

  Future<BridgeDeviceProof> sign(String payload) async {
    if (payload.isEmpty || payload.length > 4096) {
      throw ArgumentError.value(payload.length, 'payload', 'Invalid length');
    }
    final credential = await loadOrCreate();
    final keyPair = await _ed25519.newKeyPairFromSeed(credential.privateSeed);
    final signature = await _ed25519.sign(
      utf8.encode(payload),
      keyPair: keyPair,
    );
    return BridgeDeviceProof(
      deviceId: credential.deviceId,
      publicKey: credential.publicKey,
      signature: _base64UrlNoPadding(signature.bytes),
    );
  }

  Future<String> _pairingMarkerKey(String bridgeIdentityId) async {
    final normalized = bridgeIdentityId.trim();
    if (normalized.isEmpty || normalized.length > 128) {
      throw ArgumentError.value(bridgeIdentityId, 'bridgeIdentityId');
    }
    final digest = await Sha256().hash(utf8.encode(normalized));
    return 'bridge_device_identity_v1_pairing_${_base64UrlNoPadding(digest.bytes)}';
  }

  Future<bool> isPairedWith(String bridgeIdentityId) async {
    final credential = await loadOrCreate();
    final marker = await _storage.read(
      key: await _pairingMarkerKey(bridgeIdentityId),
    );
    return marker == credential.publicKey;
  }

  Future<void> markPairedWith(String bridgeIdentityId) async {
    final credential = await loadOrCreate();
    await _storage.write(
      key: await _pairingMarkerKey(bridgeIdentityId),
      value: credential.publicKey,
    );
  }

  Future<void> forgetPairing(String bridgeIdentityId) async {
    await _storage.delete(key: await _pairingMarkerKey(bridgeIdentityId));
  }
}

String bridgeHttpOriginFromWebSocketUrl(String websocketUrl) {
  final uri = Uri.parse(websocketUrl);
  return formatUriOrigin(
    scheme: uri.scheme == 'wss' ? 'https' : 'http',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

String? boundedBridgeIdentityString(Object? value, {int maxLength = 256}) =>
    _boundedOptionalString(value, maxLength: maxLength);
