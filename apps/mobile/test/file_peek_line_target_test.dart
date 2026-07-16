import 'package:ccpocket/features/file_peek/file_peek_sheet.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FilePeekReadBridge extends BridgeService {
  int readFileCalls = 0;
  int readArtifactSourceCalls = 0;
  String? sessionId;
  String? messageId;
  String? artifactId;

  @override
  Future<FileContentMessage> readFile({
    required String projectPath,
    required String filePath,
    int? maxLines,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    readFileCalls++;
    return FileContentMessage(filePath: filePath, content: 'plain');
  }

  @override
  Future<FileContentMessage> readArtifactSource({
    required String sessionId,
    required String messageId,
    required String artifactId,
    required String filePath,
    int? maxLines,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    readArtifactSourceCalls++;
    this.sessionId = sessionId;
    this.messageId = messageId;
    this.artifactId = artifactId;
    return FileContentMessage(filePath: filePath, content: 'artifact');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('line target helpers clamp reads and scroll offsets safely', () {
    expect(normalizedFilePeekInitialLine(null), isNull);
    expect(normalizedFilePeekInitialLine(-5), 1);
    expect(normalizedFilePeekInitialLine(120000), 100000);
    expect(filePeekMaxLinesForInitialLine(42), 5000);
    expect(filePeekMaxLinesForInitialLine(99980), 100000);

    expect(
      filePeekOffsetForLine(
        line: 1,
        lineExtent: 18,
        viewportExtent: 600,
        maxScrollExtent: 5000,
      ),
      0,
    );
    expect(
      filePeekOffsetForLine(
        line: 500,
        lineExtent: 18,
        viewportExtent: 600,
        maxScrollExtent: 5000,
      ),
      5000,
    );
  });

  test('artifact File Peek reloads never fall back to read_file', () async {
    final bridge = _FilePeekReadBridge();
    addTearDown(bridge.dispose);

    final result = await readFilePeekContent(
      bridge: bridge,
      projectPath: '/tmp/project',
      filePath: 'lib/main.dart',
      artifactSessionId: 'session-1',
      artifactMessageId: 'message-1',
      artifactId: 'artifact-1',
      maxLines: 5000,
    );

    expect(result.content, 'artifact');
    expect(bridge.readArtifactSourceCalls, 1);
    expect(bridge.readFileCalls, 0);
    expect(bridge.sessionId, 'session-1');
    expect(bridge.messageId, 'message-1');
    expect(bridge.artifactId, 'artifact-1');
  });

  test('partial artifact identity fails closed instead of using read_file', () async {
    final bridge = _FilePeekReadBridge();
    addTearDown(bridge.dispose);

    await expectLater(
      readFilePeekContent(
        bridge: bridge,
        projectPath: '/tmp/project',
        filePath: 'lib/main.dart',
        artifactSessionId: 'session-1',
      ),
      throwsArgumentError,
    );
    expect(bridge.readArtifactSourceCalls, 0);
    expect(bridge.readFileCalls, 0);
  });
}
