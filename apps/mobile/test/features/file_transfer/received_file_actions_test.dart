import 'package:ccpocket/features/file_transfer/ios_file_transfer_gateway.dart';
import 'package:ccpocket/features/file_transfer/received_file_actions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(iosFileTransferChannelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('export delegates the app-local file to the iOS save picker', () async {
    MethodCall? call;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (value) async {
          call = value;
          return true;
        });

    final saved = await const MethodChannelReceivedFileExportGateway()
        .exportFile(path: '/app/Documents/Downloads/report.pdf');

    expect(saved, isTrue);
    expect(call?.method, 'exportFile');
    expect(call?.arguments, {
      'path': '/app/Documents/Downloads/report.pdf',
    });
  });
}
