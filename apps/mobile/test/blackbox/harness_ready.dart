import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Captures a real Bridge harness startup without hiding an early process exit.
///
/// If the Node harness fails before binding its port, a plain
/// `Stream.firstWhere` only reports `Bad state: No element`. This wrapper keeps
/// the same READY protocol but includes the process exit code and both output
/// streams in the failure.
class HarnessReadyResult {
  HarnessReadyResult({
    required this.readyLine,
    required this.stdout,
    required this.stderr,
    required this.stdoutSubscription,
    required this.stderrSubscription,
  });

  final String readyLine;
  final String stdout;
  final String stderr;
  final StreamSubscription<String> stdoutSubscription;
  final StreamSubscription<String> stderrSubscription;

  Future<void> dispose() async {
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
  }
}

Future<HarnessReadyResult> waitForHarnessReady(
  Process process, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final ready = Completer<String>();

  final stdoutSubscription = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        stdoutBuffer.writeln(line);
        if (!ready.isCompleted && line.startsWith('READY ')) {
          ready.complete(line);
        }
      });
  final stderrSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(stderrBuffer.write);

  try {
    final readyLine = await Future.any<String>([
      ready.future,
      process.exitCode.then((exitCode) {
        throw StateError(
          'Bridge harness exited before READY '
          '(exitCode=$exitCode, stdout=${stdoutBuffer.toString().trim()}, '
          'stderr=${stderrBuffer.toString().trim()})',
        );
      }),
    ]).timeout(timeout);
    return HarnessReadyResult(
      readyLine: readyLine,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
      stdoutSubscription: stdoutSubscription,
      stderrSubscription: stderrSubscription,
    );
  } catch (_) {
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    rethrow;
  }
}
