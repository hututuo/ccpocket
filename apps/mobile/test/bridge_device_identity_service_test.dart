import 'dart:convert';
import 'dart:math';

import 'package:ccpocket/services/bridge_device_identity_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemorySecureStorage implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> unb64(String value) {
  final padding = (4 - value.length % 4) % 4;
  return base64Url.decode('$value${List<String>.filled(padding, '=').join()}');
}

Future<Map<String, dynamic>> signedIdentity(
  String nonce, {
  required SimpleKeyPair keyPair,
  String computerName = 'Studio Mac',
}) async {
  final publicKey = await keyPair.extractPublicKey();
  final digest = await Sha256().hash(publicKey.bytes);
  final identityId = 'bridge_${b64(digest.bytes)}';
  final payload = jsonEncode({
    'version': 1,
    'bridgeIdentityId': identityId,
    'publicKey': b64(publicKey.bytes),
    'bridgeInstanceId': 'bridge-instance-1',
    'computerName': computerName,
    'nonce': nonce,
    'authMode': 'paired_or_key',
    'methods': ['device_ed25519', 'api_key'],
  });
  final signature = await Ed25519().sign(
    utf8.encode(payload),
    keyPair: keyPair,
  );
  return {
    ...jsonDecode(payload) as Map<String, dynamic>,
    'signedPayload': payload,
    'signature': b64(signature.bytes),
  };
}

void main() {
  test('device credential is stable and signs challenges', () async {
    final storage = _MemorySecureStorage();
    final first = BridgeDeviceIdentityService(storage);
    final credential = await first.loadOrCreate();
    final proof = await first.sign('challenge-payload');

    final publicKey = SimplePublicKey(
      unb64(credential.publicKey),
      type: KeyPairType.ed25519,
    );
    expect(
      await Ed25519().verify(
        utf8.encode('challenge-payload'),
        signature: Signature(unb64(proof.signature), publicKey: publicKey),
      ),
      isTrue,
    );

    final restoredService = BridgeDeviceIdentityService(storage);
    final restored = await restoredService.loadOrCreate();
    expect(restored.deviceId, credential.deviceId);
    expect(restored.publicKey, credential.publicKey);

    expect(await restoredService.isPairedWith('bridge-one'), isFalse);
    await restoredService.markPairedWith('bridge-one');
    expect(await restoredService.isPairedWith('bridge-one'), isTrue);
    await restoredService.forgetPairing('bridge-one');
    expect(await restoredService.isPairedWith('bridge-one'), isFalse);
  });

  test('partial device identity fails closed instead of rotating', () async {
    final storage = _MemorySecureStorage();
    storage.values['bridge_device_identity_v1_seed'] = b64(
      List<int>.filled(32, 1),
    );

    await expectLater(
      BridgeDeviceIdentityService(storage).loadOrCreate(),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'signed identity probe verifies nonce, fingerprint and signature',
    () async {
      final keyPair = await Ed25519().newKeyPair();
      final client = MockClient((request) async {
        final nonce = request.url.queryParameters['nonce']!;
        return http.Response(
          jsonEncode(await signedIdentity(nonce, keyPair: keyPair)),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final probe = BridgeIdentityProbe(client: client, random: Random(42));

      final result = await probe.probe('http://127.0.0.1:8765');

      expect(result.document, isNotNull);
      expect(result.document!.computerName, 'Studio Mac');
      expect(result.document!.authMode, 'paired_or_key');
      probe.dispose();
    },
  );

  test('legacy 404 is an explicit compatibility result', () async {
    final probe = BridgeIdentityProbe(
      client: MockClient((_) async => http.Response('not found', 404)),
      random: Random(1),
    );

    final result = await probe.probe('http://127.0.0.1:8765');

    expect(result.document, isNull);
    probe.dispose();
  });

  test('tampered signed identity fails closed', () async {
    final keyPair = await Ed25519().newKeyPair();
    final client = MockClient((request) async {
      final nonce = request.url.queryParameters['nonce']!;
      final identity = await signedIdentity(nonce, keyPair: keyPair);
      identity['computerName'] = 'Attacker Mac';
      return http.Response(jsonEncode(identity), 200);
    });
    final probe = BridgeIdentityProbe(client: client, random: Random(42));

    await expectLater(
      probe.probe('http://127.0.0.1:8765'),
      throwsA(isA<FormatException>()),
    );
    probe.dispose();
  });

  test('signed computer name rejects display control characters', () async {
    final keyPair = await Ed25519().newKeyPair();
    final client = MockClient((request) async {
      final nonce = request.url.queryParameters['nonce']!;
      return http.Response(
        jsonEncode(
          await signedIdentity(
            nonce,
            keyPair: keyPair,
            computerName: 'Studio\nMac',
          ),
        ),
        200,
      );
    });
    final probe = BridgeIdentityProbe(client: client, random: Random(42));

    await expectLater(
      probe.probe('http://127.0.0.1:8765'),
      throwsA(isA<FormatException>()),
    );
    probe.dispose();
  });
}
