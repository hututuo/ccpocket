import 'dart:async';

import 'package:ccpocket/features/background_sync/background_sync_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(backgroundSyncHostChannelName),
          null,
        );
  });

  test('missing native plugin fails closed for a new Dart host', () async {
    final host = MethodChannelBackgroundSyncHost(
      supportsContinuation: true,
      supportsAppRefresh: true,
    );

    expect(
      await host.beginContinuation(generation: 1, reason: 'test'),
      isFalse,
    );
    expect(await host.markDartReady(), isFalse);
    expect(await host.scheduleRefresh(), isFalse);
    await host.endContinuation(generation: 1);

    await host.dispose();
  });

  test('Dart readiness uses an explicit native handshake', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(backgroundSyncHostChannelName),
          (call) async {
            methods.add(call.method);
            return {'accepted': true};
          },
        );
    final host = MethodChannelBackgroundSyncHost(
      supportsContinuation: true,
      supportsAppRefresh: true,
    );

    expect(await host.markDartReady(), isTrue);
    expect(methods, ['setDartReady']);

    await host.dispose();
  });

  test('duplicate native runId shares one operation and expiry wins', () async {
    final host = MethodChannelBackgroundSyncHost(
      supportsContinuation: true,
      supportsAppRefresh: true,
    );
    final gate = Completer<void>();
    var calls = 0;
    host.setRefreshHandler((request) async {
      calls++;
      await gate.future;
      return true;
    });
    final deadline = DateTime.now()
        .add(const Duration(seconds: 30))
        .millisecondsSinceEpoch;

    final first = _invokeFromNative(
      MethodCall('performRefresh', {
        'runId': 'same-run',
        'deadlineEpochMs': deadline,
      }),
    );
    final second = _invokeFromNative(
      MethodCall('performRefresh', {
        'runId': 'same-run',
        'deadlineEpochMs': deadline,
      }),
    );
    await _invokeFromNative(
      const MethodCall('expireRefresh', {'runId': 'same-run'}),
    );
    gate.complete();

    expect(await first, isFalse);
    expect(await second, isFalse);
    expect(calls, 1);
    expect(
      await _invokeFromNative(
        MethodCall('performRefresh', {
          'runId': 'same-run',
          'deadlineEpochMs': deadline,
        }),
      ),
      isFalse,
    );
    expect(calls, 1);

    await host.dispose();
  });

  test('native continuation expiry is correlated by generation', () async {
    final host = MethodChannelBackgroundSyncHost(
      supportsContinuation: true,
      supportsAppRefresh: true,
    );
    final expirations = <int>[];
    host.setContinuationExpirationHandler(expirations.add);

    expect(
      await _invokeFromNative(
        const MethodCall('continuationExpired', {'generation': 7}),
      ),
      isTrue,
    );
    expect(
      await _invokeFromNative(
        const MethodCall('continuationExpired', {'generation': 0}),
      ),
      isFalse,
    );
    expect(expirations, [7]);

    await host.dispose();
  });
}

Future<Object?> _invokeFromNative(MethodCall call) async {
  const codec = StandardMethodCodec();
  final response = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        backgroundSyncHostChannelName,
        codec.encodeMethodCall(call),
        response.complete,
      );
  final envelope = await response.future;
  if (envelope == null) return null;
  return codec.decodeEnvelope(envelope);
}
