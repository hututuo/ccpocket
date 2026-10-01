import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_fonts/src/google_fonts_base.dart' as font_loader;
// Test only: the plugin's documented native-channel mock context.
// ignore: depend_on_referenced_packages
import 'package:irondash_message_channel/irondash_message_channel.dart';
// ignore: depend_on_referenced_packages
import 'package:super_native_extensions/src/native/context.dart';
import 'package:path/path.dart' as path;

// Rendering uses a repository-bundled font for these asset aliases.
// Typeface metrics are not a visual/physical-device acceptance claim.
class _PageFontManifest extends Fake implements AssetManifest {
  @override
  List<String> listAssets() => [
    for (final family in ['IBMPlexSans', 'SpaceGrotesk'])
      for (final weight in [
        'Thin',
        'ExtraLight',
        'Light',
        'Regular',
        '',
        'Medium',
        'SemiBold',
        'Bold',
        'ExtraBold',
        'Black',
      ])
        for (final suffix in ['', 'Italic'])
          'page-test-fonts/$family-$weight$suffix.ttf',
  ];
}

Future<void> installPagePlatformServices() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.irondash.engine_context'),
    (call) async {
      if (call.method == 'getEngineHandle') return 1;
      throw MissingPluginException('Unexpected engine method: ${call.method}');
    },
  );
  final native = superNativeExtensionsContext as MockMessageChannelContext;
  native.registerMockMethodCallHandler('DropManager', (call) async {
    if (call.method == 'newContext' || call.method == 'registerDropFormats') {
      return null;
    }
    throw MissingPluginException('Unexpected drop method: ${call.method}');
  });
  native.registerMockMethodCallHandler('DragManager', (call) async {
    if (call.method == 'newContext') return null;
    throw MissingPluginException('Unexpected drag method: ${call.method}');
  });
  final font = File(
    path.join(
      Directory.current.path,
      'assets/fonts/code/JetBrainsMono-Regular.ttf',
    ),
  );
  expect(
    font.existsSync(),
    isTrue,
    reason: 'Use the repository-bundled test font.',
  );
  final bytes = (await font.readAsBytes()).buffer.asByteData();
  font_loader.assetManifest = _PageFontManifest();
  GoogleFonts.config.allowRuntimeFetching = false;
  messenger.setMockMessageHandler('flutter/assets', (message) async {
    if (message == null) return null;
    final name = utf8.decode(
      message.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
    );
    if (name.startsWith('page-test-fonts/')) return bytes;
    return null;
  });
}
