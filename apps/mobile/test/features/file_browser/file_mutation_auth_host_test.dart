import 'package:ccpocket/features/file_browser/file_mutation_auth_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fails closed when the installed IPA lacks the capability', () async {
    final host = FileMutationBiometricHost(
      supportedByInstalledHost: false,
      gateway: _Gateway({}),
    );

    expect((await host.snapshot()).reason, 'base_ipa_update_required');
    await expectLater(
      host.prepareKey(),
      throwsA(
        isA<FileMutationBiometricException>().having(
          (error) => error.code,
          'code',
          'base_ipa_update_required',
        ),
      ),
    );
  });

  test('parses a versioned native snapshot and bounded key material', () async {
    final gateway = _Gateway({
      'getSnapshot': {
        'supported': true,
        'nativeApiVersion': 1,
        'canEvaluateBiometrics': true,
        'keyPrepared': true,
        'deviceId': 'ios:test-device',
        'biometryType': 'faceId',
      },
      'prepareKey': {
        'deviceId': 'ios:test-device',
        'publicKey': List.filled(87, 'a').join(),
        'biometryType': 'faceId',
      },
      'signChallenge': {
        'deviceId': 'ios:test-device',
        'signature': List.filled(86, 'b').join(),
      },
    });
    final host = FileMutationBiometricHost(
      supportedByInstalledHost: true,
      gateway: gateway,
    );

    final snapshot = await host.snapshot();
    expect(snapshot.canSign, isTrue);
    expect((await host.prepareKey()).publicKey, hasLength(87));
    expect(
      (await host.sign('{"challenge":1}', reason: 'Approve')).signature,
      hasLength(86),
    );
  });

  test('rejects malformed native payloads', () async {
    final host = FileMutationBiometricHost(
      supportedByInstalledHost: true,
      gateway: _Gateway({
        'getSnapshot': {'supported': true, 'nativeApiVersion': 99},
      }),
    );

    expect((await host.snapshot()).reason, 'invalid_native_snapshot');
  });
}

class _Gateway implements FileMutationAuthNativeGateway {
  _Gateway(this.responses);

  final Map<String, Object?> responses;

  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => responses[method];
}
