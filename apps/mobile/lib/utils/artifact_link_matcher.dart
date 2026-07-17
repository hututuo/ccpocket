import '../models/messages.dart';

/// Returns the artifact explicitly associated with this Markdown link/image.
///
/// Exact content-index + href matches win. A href-only fallback is allowed only
/// when it identifies a single artifact, which keeps repeated paths in separate
/// assistant text blocks from being guessed incorrectly.
ArtifactRef? matchArtifactHref({
  required List<ArtifactRef> artifacts,
  required int textContentIndex,
  required String href,
}) {
  final hrefMatches = artifacts.where((artifact) {
    final originalHref = artifact.originalHref;
    return originalHref != null && artifactHrefsEquivalent(originalHref, href);
  }).toList(growable: false);

  final exactMatches = hrefMatches
      .where((artifact) => artifact.textContentIndex == textContentIndex)
      .toList(growable: false);
  if (exactMatches.length == 1) return exactMatches.single;
  if (exactMatches.length > 1) return null;
  if (hrefMatches.length == 1) return hrefMatches.single;
  return null;
}

bool artifactHrefsEquivalent(String left, String right) {
  if (left == right) return true;
  final decodedLeft = _decodedSafeHref(left);
  final decodedRight = _decodedSafeHref(right);
  return decodedLeft != null &&
      decodedRight != null &&
      decodedLeft == decodedRight;
}

String? _decodedSafeHref(String value) {
  var decoded = value.trim();
  if (RegExp(r'%(?:2f|5c|00)', caseSensitive: false).hasMatch(decoded)) {
    return null;
  }
  // flutter_markdown and the Bridge may observe the same path before or after
  // one layer of percent encoding. Decode exactly once to mirror the Bridge's
  // candidate parser and avoid accepting double-encoded separators.
  try {
    decoded = Uri.decodeFull(decoded);
  } on FormatException {
    // Uri.decodeFull currently reports malformed percent escapes as an
    // ArgumentError, but keep this branch for SDK/runtime compatibility.
  } on ArgumentError {
    // Preserve malformed input for exact-only matching.
  }
  if (RegExp(r'%(?:2f|5c|00)', caseSensitive: false).hasMatch(decoded)) {
    return null;
  }
  return decoded;
}

bool isExternalWebHref(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return false;
  return uri.scheme.toLowerCase() == 'http' ||
      uri.scheme.toLowerCase() == 'https';
}

/// Whether an unmatched Markdown href points at a local path and therefore
/// must not be handed to the platform URL launcher.
bool isLocalFileLikeHref(String href) {
  final value = href.trim();
  if (value.isEmpty) return false;
  if (value.startsWith('/') ||
      value.startsWith(r'\') ||
      value.startsWith('./') ||
      value.startsWith('../') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value)) {
    return true;
  }
  // Markdown commonly emits source locations such as `notes:12` and
  // `notes:12:3`. Uri parsing treats the prefix as a custom scheme, but these
  // are local file references and must never reach the platform URL launcher.
  if (RegExp(r'^[^:/\\]+:\d+(?::\d+)?$').hasMatch(value)) return true;
  final uri = Uri.tryParse(value);
  if (uri == null) return true;
  if (uri.scheme.toLowerCase() == 'file') return true;
  if (uri.hasScheme || value.startsWith('#') || value.startsWith('?')) {
    return false;
  }
  return true;
}

bool isSafeProjectRelativePath(String? path) {
  final value = path?.trim();
  if (value == null || value.isEmpty) return false;
  if (value.startsWith('/') || value.codeUnitAt(0) == 0x5c) return false;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return false;
  if (RegExp(r'%(?:2e|2f|5c|00)', caseSensitive: false).hasMatch(value)) {
    return false;
  }
  final parts = value.split(RegExp(r'[\\/]'));
  return parts.every(
    (part) => part.isNotEmpty && part != '.' && part != '..',
  );
}
