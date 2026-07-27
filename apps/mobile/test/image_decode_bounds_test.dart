import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ccpocket/features/gallery/widgets/gallery_tile.dart';
import 'package:ccpocket/features/generated_image_preview/generated_image_preview_item.dart';
import 'package:ccpocket/features/generated_image_preview/widgets/generated_image_chat_group.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/utils/data_image_decode.dart';
import 'package:ccpocket/widgets/bubbles/image_preview.dart';
import 'package:ccpocket/widgets/bubbles/user_bubble.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bounded-size render sites must cap decode resolution (cacheWidth →
/// ResizeImage): a full-resolution screenshot decode costs 20-70x the
/// memory of its on-screen size. Full-screen zoomable viewers stay
/// unbounded — these tests pin the boundary so a refactor cannot silently
/// drop the caps.
void main() {
  // Smallest valid 1x1 transparent PNG.
  final onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  Widget wrap(Widget child) => MaterialApp(
    theme: AppTheme.lightTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(body: child),
  );

  testWidgets('gallery tile bounds its decode size', (tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 200,
          height: 260,
          child: GalleryTile(
            image: const GalleryImage(
              id: 'g1',
              url: '/api/gallery/g1',
              mimeType: 'image/png',
              projectPath: '/tmp/p',
              projectName: 'p',
              addedAt: '2026-07-27T00:00:00Z',
              sizeBytes: 1,
            ),
            httpBaseUrl: 'http://127.0.0.1:9',
            timeAgo: 'now',
          ),
        ),
      ),
    );

    final image = tester.widget<ExtendedImage>(find.byType(ExtendedImage));
    expect(image.image, isA<ExtendedResizeImage>());
  });

  testWidgets('chat bubble image previews bound their decode size', (
    tester,
  ) async {
    final dataUrl = 'data:image/png;base64,${base64Encode(onePixelPng)}';
    await tester.pumpWidget(
      wrap(
        ImagePreviewWidget(
          images: [ImageRef(id: 'i1', url: dataUrl, mimeType: 'image/png')],
          httpBaseUrl: '',
        ),
      ),
    );
    await tester.pump();

    final single = tester.widget<Image>(find.byType(Image));
    expect(single.image, isA<ResizeImage>());

    await tester.pumpWidget(
      wrap(
        ImagePreviewWidget(
          images: [
            ImageRef(id: 'i1', url: dataUrl, mimeType: 'image/png'),
            ImageRef(id: 'i2', url: dataUrl, mimeType: 'image/png'),
          ],
          httpBaseUrl: '',
        ),
      ),
    );
    await tester.pump();

    for (final image in tester.widgetList<Image>(find.byType(Image))) {
      expect(image.image, isA<ResizeImage>());
    }
  });

  testWidgets('chat bubble keeps inline image URLs intact with a Bridge URL', (
    tester,
  ) async {
    final dataUrl = 'data:image/png;base64,${base64Encode(onePixelPng)}';
    await tester.pumpWidget(
      wrap(
        ImagePreviewWidget(
          images: [ImageRef(id: 'i1', url: dataUrl, mimeType: 'image/png')],
          httpBaseUrl: 'http://127.0.0.1:8765',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ExtendedImage), findsNothing);
  });

  testWidgets('chat bubble waits for its asynchronous data image decoder', (
    tester,
  ) async {
    final dataUrl = 'data:image/png;base64,${base64Encode(onePixelPng)}';
    final decoded = Completer<Uint8List?>();
    var decodeCalls = 0;
    await tester.pumpWidget(
      wrap(
        ImagePreviewWidget(
          images: [ImageRef(id: 'i1', url: dataUrl, mimeType: 'image/png')],
          httpBaseUrl: '',
          dataImageDecoder: (url) {
            decodeCalls++;
            expect(url, dataUrl);
            return decoded.future;
          },
        ),
      ),
    );

    expect(decodeCalls, 1);
    expect(find.byType(Image), findsNothing);

    decoded.complete(Uint8List.fromList(onePixelPng));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  test('large data images are decoded outside the synchronous path', () async {
    final source = Uint8List.fromList(List<int>.filled(70 * 1024, 7));
    final dataUrl = 'data:image/png;base64,${base64Encode(source)}';
    var completedSynchronously = false;

    final decoded = decodeDataImageUrl(dataUrl);
    decoded.then((_) => completedSynchronously = true);

    expect(completedSynchronously, isFalse);
    expect(await decoded, source);
  });

  test('chat bubble resolves inline, absolute, and relative image URLs', () {
    expect(
      resolveImagePreviewUrl(
        'data:image/png;base64,AAAA',
        'http://127.0.0.1:8765',
      ),
      'data:image/png;base64,AAAA',
    );
    expect(
      resolveImagePreviewUrl(
        'https://cdn.example.com/image.png',
        'http://127.0.0.1:8765',
      ),
      'https://cdn.example.com/image.png',
    );
    expect(
      resolveImagePreviewUrl('/images/image.png', 'http://127.0.0.1:8765'),
      'http://127.0.0.1:8765/images/image.png',
    );
    expect(
      resolveImagePreviewUrl('images/image.png', 'http://127.0.0.1:8765'),
      'http://127.0.0.1:8765/images/image.png',
    );
  });

  testWidgets('user bubble attachments bound their decode size', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        UserBubble(
          text: 'hi',
          imageBytesList: [Uint8List.fromList(onePixelPng)],
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
  });

  testWidgets('generated image grid tiles bound their decode size', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        GeneratedImageChatGroup(
          items: [
            GeneratedImagePreviewItem(
              id: 'a',
              bytes: Uint8List.fromList(onePixelPng),
              mimeType: 'image/png',
              prompt: 'p',
            ),
            GeneratedImagePreviewItem(
              id: 'b',
              bytes: Uint8List.fromList(onePixelPng),
              mimeType: 'image/png',
              prompt: 'p',
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, isNotEmpty);
    for (final image in images) {
      expect(image.image, isA<ResizeImage>());
    }
  });

  testWidgets('full-screen viewer stays unbounded for pinch zoom', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(FullScreenImageViewer(bytes: Uint8List.fromList(onePixelPng))),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MemoryImage>());
  });
}
