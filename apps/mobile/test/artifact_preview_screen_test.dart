import 'dart:async';
import 'dart:io';

import 'package:ccpocket/features/artifact_preview/artifact_quick_look_service.dart';
import 'package:ccpocket/features/artifact_preview/artifact_preview_screen.dart';
import 'package:ccpocket/features/artifact_preview/artifact_preview_screen_stub.dart'
    as web_stub;
import 'package:ccpocket/features/artifact_preview/artifact_transfer_service.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart'
    as webview_platform;

class _BlockingQuickLookPreviewer implements ArtifactQuickLookPreviewer {
  final dismissed = Completer<void>();
  var calls = 0;
  bool Function()? cancellationCheck;

  @override
  Future<void> previewTemporaryArtifact({
    required Future<File> Function() prepareFile,
    required String title,
    required bool Function() isCancelled,
  }) {
    calls += 1;
    cancellationCheck = isCancelled;
    return dismissed.future;
  }
}

class _FailingQuickLookPreviewer implements ArtifactQuickLookPreviewer {
  @override
  Future<void> previewTemporaryArtifact({
    required Future<File> Function() prepareFile,
    required String title,
    required bool Function() isCancelled,
  }) async {
    throw StateError('preview failed');
  }
}

class _FakeWebViewPlatform extends webview_platform.WebViewPlatform {
  @override
  webview_platform.PlatformWebViewController createPlatformWebViewController(
    webview_platform.PlatformWebViewControllerCreationParams params,
  ) => _FakeWebViewController(params);

  @override
  webview_platform.PlatformNavigationDelegate createPlatformNavigationDelegate(
    webview_platform.PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  webview_platform.PlatformWebViewWidget createPlatformWebViewWidget(
    webview_platform.PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakeWebViewController
    extends webview_platform.PlatformWebViewController {
  _FakeWebViewController(super.params) : super.implementation();

  @override
  Future<void> setJavaScriptMode(
    webview_platform.JavaScriptMode javaScriptMode,
  ) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    webview_platform.PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(webview_platform.LoadRequestParams params) async {}

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}
}

class _FakeNavigationDelegate
    extends webview_platform.PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    webview_platform.NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(
    webview_platform.PageEventCallback onPageStarted,
  ) async {}

  @override
  Future<void> setOnPageFinished(
    webview_platform.PageEventCallback onPageFinished,
  ) async {}

  @override
  Future<void> setOnHttpError(
    webview_platform.HttpResponseErrorCallback onHttpError,
  ) async {}

  @override
  Future<void> setOnProgress(
    webview_platform.ProgressCallback onProgress,
  ) async {}

  @override
  Future<void> setOnWebResourceError(
    webview_platform.WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(
    webview_platform.UrlChangeCallback onUrlChange,
  ) async {}
}

class _FakeWebViewWidget extends webview_platform.PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  final tokenA = List<String>.filled(43, 'A').join();
  final tokenB = List<String>.filled(43, 'B').join();
  final preview = Uri.parse('http://100.105.41.82:8765/artifacts/$tokenA');

  test('builds embedded and download URLs without changing the token', () {
    expect(
      embeddedArtifactPreviewUri(preview).toString(),
      '${preview.toString()}?embedded=1',
    );
    expect(
      artifactDownloadUri(preview).toString(),
      '${preview.toString()}/download',
    );
  });

  test('allows only the resolved artifact and same-origin viewer assets', () {
    expect(isAllowedArtifactPreviewNavigation(preview, preview), isTrue);
    expect(
      isAllowedArtifactPreviewNavigation(
        preview,
        Uri.parse('${preview.toString()}/content'),
      ),
      isTrue,
    );
    expect(
      isAllowedArtifactPreviewNavigation(
        preview,
        Uri.parse('${preview.toString()}/sandbox'),
      ),
      isTrue,
    );
    expect(
      isAllowedArtifactPreviewNavigation(
        preview,
        Uri.parse('http://100.105.41.82:8765/artifacts/assets/docx-viewer.js'),
      ),
      isTrue,
    );
    expect(
      isAllowedArtifactPreviewNavigation(
        preview,
        Uri.parse('http://100.105.41.82:8765/artifacts/$tokenB'),
      ),
      isFalse,
    );
    expect(
      isAllowedArtifactPreviewNavigation(
        preview,
        Uri.parse('https://example.com/file.docx'),
      ),
      isFalse,
    );
  });

  test('sanitizes downloaded filenames', () {
    expect(
      safeArtifactDownloadFilename('../report\\final.docx'),
      '.._report_final.docx',
    );
    expect(safeArtifactDownloadFilename('   '), 'download');
  });

  test('limits embedded WebView support to plugin-backed platforms', () {
    expect(supportsEmbeddedArtifactPreview(TargetPlatform.iOS), isTrue);
    expect(supportsEmbeddedArtifactPreview(TargetPlatform.android), isFalse);
    expect(supportsEmbeddedArtifactPreview(TargetPlatform.macOS), isFalse);
    expect(supportsEmbeddedArtifactPreview(TargetPlatform.windows), isFalse);
    expect(supportsEmbeddedArtifactPreview(TargetPlatform.linux), isFalse);
    expect(
      web_stub.supportsEmbeddedArtifactPreview(TargetPlatform.iOS),
      isFalse,
    );
  });

  test('enables JavaScript only for isolated HTML and local DOCX renderers', () {
    expect(
      artifactPreviewRequiresJavaScript(
        'report.docx',
        'application/octet-stream',
      ),
      isTrue,
    );
    expect(
      artifactPreviewRequiresJavaScript(
        'report',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      ),
      isTrue,
    );
    expect(artifactPreviewRequiresJavaScript('page.html', 'text/html'), isTrue);
    expect(
      artifactPreviewRequiresJavaScript('report.pdf', 'application/pdf'),
      isFalse,
    );
  });

  testWidgets('Office preview uses injected Quick Look and gates actions', (
    tester,
  ) async {
    final quickLook = _BlockingQuickLookPreviewer();
    addTearDown(() {
      if (!quickLook.dismissed.isCompleted) quickLook.dismissed.complete();
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArtifactPreviewScreen(
          previewUrl: preview,
          filename: 'report.xlsx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          sizeBytes: 120557,
          quickLookPreviewer: quickLook,
        ),
      ),
    );
    await tester.pump();

    expect(quickLook.calls, 1);
    expect(quickLook.cancellationCheck!(), isFalse);
    expect(find.byType(WebViewWidget), findsNothing);
    final shareButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.byIcon(Icons.ios_share),
        matching: find.byType(OutlinedButton),
      ),
    );
    final downloadButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.byIcon(Icons.download_outlined),
        matching: find.byType(FilledButton),
      ),
    );
    expect(shareButton.onPressed, isNull);
    expect(downloadButton.onPressed, isNull);

    quickLook.dismissed.complete();
    await tester.pump();

    final popScope = tester.widget<PopScope<void>>(find.byType(PopScope<void>));
    expect(popScope.canPop, isTrue);
    expect(
      find.ancestor(
        of: find.byIcon(Icons.visibility_outlined),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(find.text('Preview'), findsOneWidget);
  });

  testWidgets('disposing an Office preview cancels the native handoff', (
    tester,
  ) async {
    final quickLook = _BlockingQuickLookPreviewer();
    addTearDown(() {
      if (!quickLook.dismissed.isCompleted) quickLook.dismissed.complete();
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArtifactPreviewScreen(
          previewUrl: preview,
          filename: 'report.xlsx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          sizeBytes: 120557,
          quickLookPreviewer: quickLook,
        ),
      ),
    );
    await tester.pump();
    expect(quickLook.cancellationCheck!(), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(quickLook.cancellationCheck!(), isTrue);
    quickLook.dismissed.complete();
    await tester.pump();
  });

  testWidgets('failed Quick Look preview falls back to the WebView preview', (
    tester,
  ) async {
    // E.4 §5: any Quick Look failure falls back to the WebView preview, not
    // just the explicit "unsupported" signal.
    webview_platform.WebViewPlatform.instance = _FakeWebViewPlatform();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArtifactPreviewScreen(
          previewUrl: preview,
          filename: 'report.xlsx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          sizeBytes: 120557,
          quickLookPreviewer: _FailingQuickLookPreviewer(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    // The failure is surfaced as a non-blocking notice, not a dead end.
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('file browser preview delegates Download to resumable transfer', (
    tester,
  ) async {
    final quickLook = _BlockingQuickLookPreviewer();
    var downloadRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArtifactPreviewScreen(
          previewUrl: preview,
          filename: 'report.xlsx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          sizeBytes: 120557,
          quickLookPreviewer: quickLook,
          onDownloadRequested: () async => downloadRequests += 1,
        ),
      ),
    );
    await tester.pump();
    quickLook.dismissed.complete();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump();
    expect(downloadRequests, 1);
  });

  testWidgets(
    'file browser preview explains when resumable download is unavailable',
    (tester) async {
      final quickLook = _BlockingQuickLookPreviewer();
      var downloadRequests = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ArtifactPreviewScreen(
            previewUrl: preview,
            filename: 'report.xlsx',
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            sizeBytes: 120557,
            quickLookPreviewer: quickLook,
            onDownloadRequested: () async => downloadRequests += 1,
            downloadUnavailableMessage: () =>
                'Save this Mac connection before downloading files',
          ),
        ),
      );
      await tester.pump();
      quickLook.dismissed.complete();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pump();
      expect(downloadRequests, 0);
      expect(
        find.text('Save this Mac connection before downloading files'),
        findsOneWidget,
      );
    },
  );
}
