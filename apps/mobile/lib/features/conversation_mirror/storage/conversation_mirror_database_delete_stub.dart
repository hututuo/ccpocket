Future<void> deleteConversationMirrorDatabaseForDowngrade(String path) {
  throw UnsupportedError(
    'Conversation mirror database downgrade recovery is unavailable.',
  );
}

Future<bool> prepareConversationMirrorLegacyDatabaseForOpen(
  String path, {
  required int schemaVersion,
}) async => false;
