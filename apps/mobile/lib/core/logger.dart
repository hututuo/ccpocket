import 'package:talker/talker.dart';

/// Global [Talker] instance shared across the entire app.
///
/// Usage:
/// ```dart
/// import 'package:ccpocket/core/logger.dart';
/// logger.info('message');
/// logger.error('failed', exception, stackTrace);
/// ```
final logger = Talker(
  // Keep diagnostics available on the in-app log screen without allowing a
  // long-running client to grow an unbounded in-memory history.
  settings: TalkerSettings(useConsoleLogs: true, maxHistoryItems: 1000),
  logger: TalkerLogger(settings: TalkerLoggerSettings(enableColors: false)),
);
