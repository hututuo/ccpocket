import 'package:ccpocket/features/file_transfer/file_transfer_service.dart';
import 'package:ccpocket/features/file_transfer/ios_file_transfer_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ccpocket/file_transfer_support_test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'advertises transfer only after native iOS capability probe passes',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getSupportInfo');
            return <String, Object>{
              'supported': true,
              'iosMajor': 26,
              'iosMinor': 1,
              'iosPatch': 0,
              'nativeApiVersion': fileTransferNativeApiVersion,
              'appVersion': '1.72.1',
              'buildNumber': '42',
            };
          });

      final support = await const IosFileTransferGateway(
        channel,
      ).probeSupport();

      expect(support.supported, isTrue);
      expect(support.reason, 'supported');
      expect(support.iosMajor, 26);
      expect(support.nativeApiVersion, fileTransferNativeApiVersion);
      expect(support.appVersion, '1.72.1');
      expect(support.buildNumber, '42');
    },
  );

  test('rejects an iOS version below the native minimum', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <String, Object>{
            'supported': false,
            'iosMajor': minimumIosFileTransferMajorVersion - 1,
            'iosMinor': 8,
            'iosPatch': 1,
            'nativeApiVersion': fileTransferNativeApiVersion,
          },
        );

    final support = await const IosFileTransferGateway(channel).probeSupport();

    expect(support.supported, isFalse);
    expect(support.reason, 'ios_version_unsupported');
  });

  test('rejects an old native shell even on a supported iOS version', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <String, Object>{
            'supported': true,
            'iosMajor': 26,
            'iosMinor': 1,
            'iosPatch': 0,
            'nativeApiVersion': fileTransferNativeApiVersion - 1,
          },
        );

    final support = await const IosFileTransferGateway(channel).probeSupport();

    expect(support.supported, isFalse);
    expect(support.reason, 'native_api_unsupported');
  });

  test(
    'missing native plugin fails closed before any transfer request',
    () async {
      final gateway = const IosFileTransferGateway(channel);

      final support = await gateway.probeSupport();

      expect(support.supported, isFalse);
      expect(support.reason, 'native_plugin_missing');
      await expectLater(
        gateway.pickFile(maxSizeBytes: 1),
        throwsA(
          isA<FileTransferException>().having(
            (error) => error.code,
            'code',
            'native_plugin_unavailable',
          ),
        ),
      );
    },
  );

  test('non-iOS gateway never advertises file transfer support', () async {
    final support = await const UnsupportedFileTransferGateway().probeSupport();

    expect(support.supported, isFalse);
    expect(support.reason, 'platform_unsupported');
  });
}
