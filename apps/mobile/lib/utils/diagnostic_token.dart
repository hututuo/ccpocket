/// Returns a stable, non-reversible token suitable for correlating local logs
/// without writing raw conversation IDs or source fingerprints.
String diagnosticToken(String namespace, String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in '$namespace\u0000$value'.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
