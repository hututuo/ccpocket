import 'package:flutter/services.dart';

import 'file_transfer_service.dart';
import 'ios_file_transfer_gateway.dart';

abstract interface class ReceivedFileExportGateway {
  Future<bool> exportFile({required String path});
}

class MethodChannelReceivedFileExportGateway
    implements ReceivedFileExportGateway {
  const MethodChannelReceivedFileExportGateway([
    this._channel = const MethodChannel(iosFileTransferChannelName),
  ]);

  final MethodChannel _channel;

  @override
  Future<bool> exportFile({required String path}) async {
    try {
      return await _channel.invokeMethod<bool>('exportFile', {'path': path}) ??
          false;
    } on PlatformException catch (error) {
      throw FileTransferException(error.code, error.message);
    } on MissingPluginException {
      throw const FileTransferException('native_plugin_unavailable');
    }
  }
}
