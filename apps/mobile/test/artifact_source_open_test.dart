import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SourceBridgeService extends BridgeService {
  final controller = StreamController<(ServerMessage, String?)>.broadcast();
  FileContentMessage readResult = const FileContentMessage(
    filePath: 'lib/main.dart',
    content: '',
    error: 'changed',
    errorCode: 'artifact_changed',
  );
  Object? readError;
  int resolveCalls = 0;
  int readArtifactSourceCalls = 0;
  String? readFilePath;
  int? readMaxLines;
  String? readSessionId;
  String? readMessageId;
  String? readArtifactId;

  void emit(ServerMessage message, {required String sessionId}) {
    controller.add((message, sessionId));
  }

  @override
  bool get isConnected => true;

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) => controller
      .stream
      .where((event) => event.$2 == sessionId)
      .map((event) => event.$1);

  @override
  void send(ClientMessage message) {}

  @override
  void requestSessionHistory(String sessionId) {}

  @override
  Future<ResolvedArtifact> resolveArtifact({
    required String sessionId,
    required String messageId,
    required String artifactId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    resolveCalls++;
    return ResolvedArtifact(
      artifactId: artifactId,
      url: Uri.parse(
        'http://localhost:8765/artifacts/${List.filled(43, 'A').join()}',
      ),
    );
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
    readFilePath = filePath;
    readMaxLines = maxLines;
    readSessionId = sessionId;
    readMessageId = messageId;
    readArtifactId = artifactId;
    final error = readError;
    if (error != null) throw error;
    return readResult;
  }

  @override
  void dispose() {
    controller.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('source validates before an exact File Peek read', (
    tester,
  ) async {
    final bridge = _SourceBridgeService();
    final streaming = StreamingStateCubit();
    final cubit = ChatSessionCubit(
      sessionId: 'session-1',
      bridge: bridge,
      streamingCubit: streaming,
      initialProjectPath: '/tmp/worktree',
    );
    final scrollController = AutoScrollController();
    addTearDown(bridge.dispose);
    addTearDown(streaming.close);
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      RepositoryProvider<BridgeService>.value(
        value: bridge,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ChatSessionCubit>.value(value: cubit),
            BlocProvider<StreamingStateCubit>.value(value: streaming),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: ChatMessageList(
                sessionId: 'session-1',
                scrollController: scrollController,
                httpBaseUrl: 'http://localhost:8765',
                onRetryMessage: null,
                collapseToolResults: null,
                projectPath: '/tmp/worktree',
              ),
            ),
          ),
        ),
      ),
    );
    bridge.emit(
      const ToolResultMessage(
        toolUseId: 'tool-source',
        toolName: 'Read',
        content: 'Source file',
        artifacts: [
          ArtifactRef(
            id: 'artifact-source',
            filename: 'main.dart',
            mimeType: 'text/x-dart',
            sizeBytes: 128,
            kind: 'source',
            source: 'structured_tool',
            projectRelativePath: 'lib/main.dart',
            line: 42,
          ),
        ],
      ),
      sessionId: 'session-1',
    );
    await tester.pump();

    await tester.tap(
      find.byKey(
        const ValueKey('chat_intermediate_disclosure_partial:tool:tool-source'),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(
        const ValueKey(
          'chat_process_disclosure_partial:tool:tool-source:segment:leading:tool-result:tool-source',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tool_result_disclosure')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('artifact_attachment_artifact-source')),
    );
    await tester.pump();

    expect(bridge.resolveCalls, 0);
    expect(bridge.readArtifactSourceCalls, 1);
    expect(find.text('This file is no longer available.'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(ChatMessageList)),
    ).clearSnackBars();
    await tester.pumpAndSettle();

    bridge.readError = const ArtifactSourceReadException(
      code: 'artifact_source_read_unsupported',
      message: 'unsupported',
    );
    await tester.tap(
      find.byKey(const ValueKey('artifact_attachment_artifact-source')),
    );
    await tester.pump();
    expect(bridge.resolveCalls, 0);
    expect(bridge.readArtifactSourceCalls, 2);
    expect(
      find.text('Update the Bridge on your computer, then reconnect.'),
      findsOneWidget,
    );
    ScaffoldMessenger.of(
      tester.element(find.byType(ChatMessageList)),
    ).clearSnackBars();
    await tester.pumpAndSettle();

    bridge.readError = null;
    bridge.readResult = const FileContentMessage(
      filePath: 'lib/main.dart',
      content: 'void main() {}',
      language: 'dart',
    );
    await tester.tap(
      find.byKey(const ValueKey('artifact_attachment_artifact-source')),
    );
    await tester.pump();
    await tester.pump();

    expect(bridge.resolveCalls, 0);
    expect(bridge.readArtifactSourceCalls, 3);
    expect(bridge.readFilePath, 'lib/main.dart');
    expect(bridge.readMaxLines, greaterThanOrEqualTo(42));
    expect(bridge.readSessionId, 'session-1');
    expect(bridge.readMessageId, 'tool-source');
    expect(bridge.readArtifactId, 'artifact-source');
    expect(
      find.byKey(const ValueKey('file_peek_initial_line_label')),
      findsOneWidget,
    );
    expect(find.text('Line 42'), findsOneWidget);
    await cubit.close();
  });
}
