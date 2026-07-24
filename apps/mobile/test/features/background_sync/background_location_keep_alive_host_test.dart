import 'package:ccpocket/features/background_sync/background_location_keep_alive_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ccpocket/background_location_test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'an older base IPA fails closed without invoking a native channel',
    () async {
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            nativeCalls++;
            return <String, Object?>{};
          });
      final host = MethodChannelBackgroundLocationKeepAliveHost(
        supportedByInstalledHost: false,
        channel: channel,
      );
      addTearDown(host.dispose);

      final snapshot = await host.start();

      expect(snapshot.supported, isFalse);
      expect(snapshot.pauseReason, 'base_app_update_required');
      expect(nativeCalls, 0);
    },
  );

  test('parses only the bounded keep-alive health snapshot', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getSnapshot');
          return <String, Object?>{
            'supported': true,
            'nativeApiVersion': 1,
            'authorization': 'authorizedAlways',
            'active': true,
            'lowPowerModeEnabled': false,
            'thermalState': 'nominal',
          };
        });
    final host = MethodChannelBackgroundLocationKeepAliveHost(
      supportedByInstalledHost: true,
      channel: channel,
    );
    addTearDown(host.dispose);

    final snapshot = await host.getSnapshot();

    expect(snapshot.supported, isTrue);
    expect(snapshot.hasAlwaysAuthorization, isTrue);
    expect(snapshot.active, isTrue);
    expect(snapshot.lowPowerModeEnabled, isFalse);
    expect(snapshot.thermalState, 'nominal');
  });

  test('malformed native data fails closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          return <String, Object?>{
            'supported': true,
            'nativeApiVersion': 1,
            'authorization': 'authorizedAlways',
            'active': 'yes',
            'lowPowerModeEnabled': false,
            'thermalState': 'nominal',
          };
        });
    final host = MethodChannelBackgroundLocationKeepAliveHost(
      supportedByInstalledHost: true,
      channel: channel,
    );
    addTearDown(host.dispose);

    final snapshot = await host.start();

    expect(snapshot.supported, isFalse);
    expect(snapshot.pauseReason, 'invalid_snapshot_response');
  });
}
