class ArtifactPreviewAccess {
  const ArtifactPreviewAccess({
    required this.previewUrl,
    required this.expiresAt,
  });

  final Uri previewUrl;
  final String? expiresAt;
}

typedef ArtifactPreviewAccessRefresher =
    Future<ArtifactPreviewAccess> Function();

bool artifactPreviewAccessNeedsRefresh(
  String? expiresAt, {
  DateTime? now,
  Duration safetyWindow = const Duration(seconds: 15),
}) {
  final expiry = DateTime.tryParse(expiresAt ?? '')?.toUtc();
  if (expiry == null) return false;
  final threshold = (now ?? DateTime.now()).toUtc().add(safetyWindow);
  return !expiry.isAfter(threshold);
}
