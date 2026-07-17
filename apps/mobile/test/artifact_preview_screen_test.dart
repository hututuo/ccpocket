import 'package:ccpocket/features/artifact_preview/artifact_preview_screen.dart';
import 'package:ccpocket/features/artifact_preview/artifact_preview_screen_stub.dart'
    as web_stub;
import 'package:ccpocket/features/artifact_preview/artifact_transfer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('enables JavaScript only for the local DOCX renderer', () {
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
    expect(
      artifactPreviewRequiresJavaScript('report.pdf', 'application/pdf'),
      isFalse,
    );
  });
}
