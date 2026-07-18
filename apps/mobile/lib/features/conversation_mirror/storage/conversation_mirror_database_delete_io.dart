import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Deletes only the independent conversation-mirror database after a future
/// schema is detected by the Linux/Windows compatibility opener.
Future<void> deleteConversationMirrorDatabaseForDowngrade(String path) async {
  sqfliteFfiInit();
  await databaseFactoryFfi.deleteDatabase(path);
}

/// Preflights the legacy Linux/Windows opener, which cannot receive an
/// onDowngrade callback and otherwise silently rewrites user_version.
Future<bool> prepareConversationMirrorLegacyDatabaseForOpen(
  String path, {
  required int schemaVersion,
}) async {
  if (!await File(path).exists()) return false;
  sqfliteFfiInit();
  final database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
  );
  try {
    final existingVersion = Sqflite.firstIntValue(
      await database.rawQuery('PRAGMA user_version'),
    );
    if (existingVersion == null || existingVersion <= schemaVersion) {
      return false;
    }
  } finally {
    await database.close();
  }
  await deleteConversationMirrorDatabaseForDowngrade(path);
  return true;
}
