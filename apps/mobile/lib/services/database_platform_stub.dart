import 'package:sqflite/sqflite.dart';

typedef DatabaseOpenFunction =
    Future<Database> Function({
      required int version,
      required OnDatabaseCreateFn onCreate,
      required OnDatabaseVersionChangeFn onUpgrade,
    });

typedef DatabaseOpenOptionsFunction =
    Future<Database> Function(OpenDatabaseOptions options);

class PlatformDatabaseOpenConfig {
  const PlatformDatabaseOpenConfig({
    required this.path,
    required this.open,
    required this.openOptions,
  });

  final String path;
  final DatabaseOpenFunction open;
  final DatabaseOpenOptionsFunction openOptions;
}

Future<PlatformDatabaseOpenConfig?> getPlatformDatabaseOpenConfig(
  String dbName,
) async {
  return null;
}
