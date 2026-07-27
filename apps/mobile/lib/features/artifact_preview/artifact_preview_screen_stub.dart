import 'package:flutter/widgets.dart';

import 'artifact_preview_access.dart';

export 'artifact_preview_access.dart';

bool supportsEmbeddedArtifactPreview([TargetPlatform? platform]) => false;

/// Compile-safe placeholder for platforms without a native WebView backend.
///
/// [supportsEmbeddedArtifactPreview] always returns false here, so production
/// navigation keeps using the existing external-browser fallback.
class ArtifactPreviewScreen extends StatelessWidget {
  final Uri previewUrl;
  final String filename;
  final String mimeType;
  final int sizeBytes;
  final String? expiresAt;
  final ArtifactPreviewAccessRefresher? accessRefresher;
  final Future<void> Function()? onDownloadRequested;
  final String? Function()? downloadUnavailableMessage;

  const ArtifactPreviewScreen({
    super.key,
    required this.previewUrl,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    this.expiresAt,
    this.accessRefresher,
    this.onDownloadRequested,
    this.downloadUnavailableMessage,
  });

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
