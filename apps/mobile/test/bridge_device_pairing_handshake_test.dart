import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/services/bridge_device_identity_service.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Mac approval gates application traffic then resumes with a signed device',
    () async {
      final storage = _MemorySecureStorage();
      final identityService = BridgeDeviceIdentityService(storage);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final outgoingTypes = <String>[];
      final signatureVerified = Completer<void>();
      var pairingRequests = 0;
      const bridgeIdentityId = 'bridge_test_identity';
      const bridgeInstanceId = 'bridge-test-source';

      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        final firstExpiry = DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String();
        socket.add(
          jsonEncode({
            'type': 'bridge_device_challenge',
            'challengeId': 'challenge-initial',
            'nonce': 'nonce_initial_1234567890',
            'expiresAt': firstExpiry,
            'bridgeIdentityId': bridgeIdentityId,
            'bridgeInstanceId': bridgeInstanceId,
          }),
        );
        socket.listen((data) async {
          final message = jsonDecode(data as String) as Map<String, dynamic>;
          final type = message['type'] as String;
          outgoingTypes.add(type);
          if (type == 'device_pairing_request') {
            pairingRequests += 1;
            if (pairingRequests == 1) {
              socket.add(
                jsonEncode({
                  'type': 'bridge_pairing_pending',
                  'requestId': 'request-1',
                  'confirmationCode': '482731',
                  'expiresAt': firstExpiry,
                  'status': 'pending',
                  'deviceId': message['deviceId'],
                }),
              );
              return;
            }
            final authExpiry = DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 30))
                .toIso8601String();
            socket.add(
              jsonEncode({
                'type': 'bridge_pairing_pending',
                'requestId': 'request-1',
                'expiresAt': authExpiry,
                'status': 'paired',
                'deviceId': message['deviceId'],
              }),
            );
            socket.add(
              jsonEncode({
                'type': 'bridge_device_challenge',
                'challengeId': 'challenge-approved',
                'nonce': 'nonce_approved_1234567890',
                'expiresAt': authExpiry,
                'bridgeIdentityId': bridgeIdentityId,
                'bridgeInstanceId': bridgeInstanceId,
              }),
            );
            return;
          }
          if (type == 'device_auth') {
            final payload = jsonEncode({
              'challengeId': message['challengeId'],
              'nonce': message['nonce'],
              'expiresAt': message['expiresAt'],
              'bridgeIdentityId': message['bridgeIdentityId'],
              'bridgeInstanceId': message['bridgeInstanceId'],
              'deviceId': message['deviceId'],
            });
            final publicKey = SimplePublicKey(
              base64Url.decode('${message['publicKey']}='),
              type: KeyPairType.ed25519,
            );
            final signature = base64Url.decode('${message['signature']}==');
            final valid = await Ed25519().verify(
              utf8.encode(payload),
              signature: Signature(signature, publicKey: publicKey),
            );
            if (!valid) {
              signatureVerified.completeError(
                StateError('Device signature was invalid'),
              );
              return;
            }
            signatureVerified.complete();
            socket.add(
              jsonEncode({
                'type': 'bridge_device_authenticated',
                'deviceId': message['deviceId'],
                'bridgeIdentityId': bridgeIdentityId,
                'httpSessionToken': 'device-http-token',
              }),
            );
            socket.add(
              jsonEncode({'type': 'session_list', 'sessions': const []}),
            );
          }
        });
      });

      final bridge = BridgeService(deviceIdentityService: identityService);
      try {
        final pending = bridge.devicePairingChanges.firstWhere(
          (snapshot) => snapshot.needsMacApproval,
        );
        bridge.connect(
          'ws://127.0.0.1:${server.port}',
          devicePairingSupported: true,
          expectedBridgeIdentityId: bridgeIdentityId,
        );

        final pendingSnapshot = await pending.timeout(
          const Duration(seconds: 2),
        );
        expect(pendingSnapshot.confirmationCode, '482731');
        expect(outgoingTypes, isNot(contains('list_sessions')));
        expect(
          bridge.currentBridgeConnectionState,
          BridgeConnectionState.connecting,
        );

        await signatureVerified.future.timeout(const Duration(seconds: 4));
        await _waitUntil(
          () => bridge.hasAuthoritativeSessionListForCurrentConnection,
        );
        await _waitUntil(
          () =>
              outgoingTypes.contains('client_capabilities') &&
              outgoingTypes.contains('list_sessions'),
        );
        expect(outgoingTypes, contains('client_capabilities'));
        expect(outgoingTypes, contains('list_sessions'));
        expect(
          bridge.currentDevicePairing.phase,
          BridgeDevicePairingPhase.authenticated,
        );
        expect(await identityService.isPairedWith(bridgeIdentityId), isTrue);
      } finally {
        bridge.disconnect();
        bridge.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      }
    },
  );

  test(
    'paired-or-key API connection enrolls then removes the legacy key',
    () async {
      final storage = _MemorySecureStorage();
      final identityService = BridgeDeviceIdentityService(storage);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final enrolled = Completer<void>();
      const bridgeIdentityId = 'bridge_migration_identity';

      server.transform(WebSocketTransformer()).listen((socket) {
        sockets.add(socket);
        socket.add(jsonEncode({'type': 'session_list', 'sessions': const []}));
        socket.listen((data) {
          final message = jsonDecode(data as String) as Map<String, dynamic>;
          if (message['type'] != 'device_pairing_request') return;
          socket.add(
            jsonEncode({
              'type': 'bridge_pairing_pending',
              'requestId': message['deviceId'],
              'expiresAt': DateTime.now().toUtc().toIso8601String(),
              'status': 'paired',
              'deviceId': message['deviceId'],
            }),
          );
          if (!enrolled.isCompleted) enrolled.complete();
        });
      });

      final bridge = BridgeService(deviceIdentityService: identityService);
      try {
        bridge.connect(
          'ws://127.0.0.1:${server.port}?token=legacy-key',
          devicePairingSupported: true,
          deviceEnrollmentSupported: true,
          expectedBridgeIdentityId: bridgeIdentityId,
        );

        await enrolled.future.timeout(const Duration(seconds: 2));
        await _waitUntil(
          () =>
              bridge.currentDevicePairing.phase ==
              BridgeDevicePairingPhase.authenticated,
        );
        await _waitUntil(() => !bridge.lastUrl!.contains('token='));
        expect(await identityService.isPairedWith(bridgeIdentityId), isTrue);
        expect(Uri.parse(bridge.lastUrl!).queryParameters['token'], isNull);
        expect(bridge.hasAuthoritativeSessionListForCurrentConnection, isTrue);
      } finally {
        bridge.disconnect();
        bridge.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      }
    },
  );

  test('key-only enrollment keeps the API key required on reconnect', () async {
    final storage = _MemorySecureStorage();
    final identityService = BridgeDeviceIdentityService(storage);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final enrolled = Completer<void>();
    const bridgeIdentityId = 'bridge_key_only_identity';

    server.transform(WebSocketTransformer()).listen((socket) {
      sockets.add(socket);
      socket.add(jsonEncode({'type': 'session_list', 'sessions': const []}));
      socket.listen((data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (message['type'] != 'device_pairing_request') return;
        socket.add(
          jsonEncode({
            'type': 'bridge_pairing_pending',
            'requestId': message['deviceId'],
            'expiresAt': DateTime.now().toUtc().toIso8601String(),
            'status': 'paired',
            'deviceId': message['deviceId'],
          }),
        );
        if (!enrolled.isCompleted) enrolled.complete();
      });
    });

    final bridge = BridgeService(deviceIdentityService: identityService);
    try {
      bridge.connect(
        'ws://127.0.0.1:${server.port}?token=legacy-key',
        deviceEnrollmentSupported: true,
        expectedBridgeIdentityId: bridgeIdentityId,
      );

      await enrolled.future.timeout(const Duration(seconds: 2));
      await _waitUntil(
        () =>
            bridge.currentDevicePairing.phase ==
            BridgeDevicePairingPhase.authenticated,
      );
      expect(await identityService.isPairedWith(bridgeIdentityId), isTrue);
      expect(Uri.parse(bridge.lastUrl!).queryParameters['token'], 'legacy-key');
      expect(bridge.hasAuthoritativeSessionListForCurrentConnection, isTrue);
    } finally {
      bridge.disconnect();
      bridge.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    }
  });
}
