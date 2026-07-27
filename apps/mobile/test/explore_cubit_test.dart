import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/explore/explore_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ccpocket/features/explore/state/explore_cubit.dart';
import 'package:ccpocket/features/explore/state/explore_state.dart';
import 'package:ccpocket/features/explore/widgets/explore_empty_state.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/theme/app_theme.dart';

class _TestBridgeService extends BridgeService {
  _TestBridgeService({
    this.capabilities = const {fileListRequestCorrelationCapability},
  });

  final Set<String> capabilities;
  final _fileContentController =
      StreamController<FileContentMessage>.broadcast();
  final _fileListMessageController =
      StreamController<FileListMessage>.broadcast();
  final _messageController = StreamController<ServerMessage>.broadcast();
  final sentMessages = <ClientMessage>[];

  @override
  Stream<FileContentMessage> get fileContent => _fileContentController.stream;

  @override
  Stream<FileListMessage> get fileListMessages =>
      _fileListMessageController.stream;

  @override
  Stream<ServerMessage> get messages => _messageController.stream;

  @override
  Set<String> get bridgeCapabilities => capabilities;

  void emitFileList(FileListMessage message) {
    _fileListMessageController.add(message);
  }

  void emitFileContent(FileContentMessage message) {
    _fileContentController.add(message);
  }

  void emitMessage(ServerMessage message) {
    _messageController.add(message);
  }

  @override
  bool get isConnected => true;

  @override
  void send(ClientMessage message) {
    sentMessages.add(message);
  }

  @override
  void dispose() {
    _fileContentController.close();
    _fileListMessageController.close();
    _messageController.close();
    super.dispose();
  }
}

void main() {
  group('buildExploreEntries', () {
    test('builds root entries from flat file list', () {
      final entries = buildExploreEntries([
        'README.md',
        'lib/main.dart',
        'lib/app.dart',
        'test/widget_test.dart',
      ], currentPath: '');

      expect(entries.map((entry) => (entry.name, entry.isDirectory)).toList(), [
        ('lib', true),
        ('test', true),
        ('README.md', false),
      ]);
    });

    test('builds nested entries for current directory', () {
      final entries = buildExploreEntries([
        'lib/main.dart',
        'lib/src/foo.dart',
        'lib/src/bar.dart',
        'lib/widgets/button.dart',
      ], currentPath: 'lib');

      expect(entries.map((entry) => (entry.name, entry.isDirectory)).toList(), [
        ('src', true),
        ('widgets', true),
        ('main.dart', false),
      ]);
    });

    test('sorts directories before files and alphabetically', () {
      final entries = buildExploreEntries([
        'zeta.md',
        'alpha.txt',
        'docs/guide.md',
        'assets/logo.png',
      ], currentPath: '');

      expect(entries.map((entry) => entry.name).toList(), [
        'assets',
        'docs',
        'alpha.txt',
        'zeta.md',
      ]);
    });

    test('collapses duplicate directory entries', () {
      final entries = buildExploreEntries([
        'lib/src/foo.dart',
        'lib/src/bar.dart',
        'lib/src/deep/baz.dart',
      ], currentPath: 'lib');

      expect(entries.where((entry) => entry.name == 'src').length, 1);
    });

    test('returns empty list when there are no files', () {
      expect(buildExploreEntries(const [], currentPath: ''), isEmpty);
    });
  });

  group('path helpers', () {
    test('returns parent directory for nested path', () {
      expect(parentDirectoryOf('lib/src/widgets'), 'lib/src');
      expect(parentDirectoryOf('lib'), '');
    });

    test('normalizes invalid path to nearest existing parent', () {
      expect(
        normalizeExplorePath([
          'lib/main.dart',
          'lib/src/app.dart',
          'test/widget_test.dart',
        ], 'lib/src/missing'),
        'lib/src',
      );
      expect(
        normalizeExplorePath([
          'lib/main.dart',
          'test/widget_test.dart',
        ], 'docs/reference'),
        '',
      );
    });

    test('builds breadcrumb paths', () {
      expect(breadcrumbsForPath('lib/src/widgets'), [
        'lib',
        'lib/src',
        'lib/src/widgets',
      ]);
    });

    test('updates recent file history with dedupe and cap', () {
      final updated = updateRecentFileHistory([
        'lib/a.dart',
        'lib/b.dart',
        'lib/c.dart',
      ], 'lib/b.dart');
      expect(updated, ['lib/b.dart', 'lib/a.dart', 'lib/c.dart']);

      final capped = updateRecentFileHistory(
        List.generate(10, (i) => 'lib/file_$i.dart'),
        'lib/new.dart',
      );
      expect(capped.length, 10);
      expect(capped.first, 'lib/new.dart');
      expect(capped.last, 'lib/file_8.dart');
    });
  });

  group('ExploreEmptyState', () {
    testWidgets('renders empty state copy', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ExploreEmptyState())),
      );

      expect(find.text('No files to explore'), findsOneWidget);
      expect(
        find.textContaining('No visible files were found'),
        findsOneWidget,
      );
    });
  });

  group('Explore recent files', () {
    testWidgets('shows when the bridge truncated the file list', (
      tester,
    ) async {
      final bridge = _TestBridgeService();
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        RepositoryProvider<BridgeService>.value(
          value: bridge,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const ExploreScreen(
              sessionId: 'session-1',
              projectPath: '/tmp/project',
            ),
          ),
        ),
      );
      final request =
          jsonDecode(bridge.sentMessages.single.toJson())
              as Map<String, dynamic>;
      bridge.emitFileList(
        FileListMessage(
          files: const ['lib/main.dart', 'README.md'],
          requestId: request['requestId'] as String,
          projectPath: '/tmp/project',
          truncated: true,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('explore_file_list_truncated_notice')),
        findsOneWidget,
      );
      expect(find.text('Showing the first 2 entries'), findsOneWidget);
    });

    testWidgets('shows recent open files only and opens file peek', (
      tester,
    ) async {
      final bridge = _TestBridgeService();
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        RepositoryProvider<BridgeService>.value(
          value: bridge,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const ExploreScreen(
              sessionId: 'session-1',
              projectPath: '/tmp/project',
              initialFiles: ['lib/main.dart', 'docs/readme.md'],
              recentPeekedFiles: ['lib/main.dart'],
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('explore_recent_files_button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Recent open files'), findsOneWidget);
      expect(find.text('Current location'), findsNothing);
      expect(find.text('Project root'), findsNothing);

      await tester.tap(find.text('main.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final payload = bridge.sentMessages
          .map(
            (message) => jsonDecode(message.toJson()) as Map<String, dynamic>,
          )
          .singleWhere((message) => message['type'] == 'read_file');
      expect(payload['type'], 'read_file');
      expect(payload['projectPath'], '/tmp/project');
      expect(payload['filePath'], 'lib/main.dart');
      expect(payload['requestId'], isNotEmpty);

      bridge.emitFileContent(
        FileContentMessage(
          requestId: payload['requestId'] as String,
          filePath: 'lib/main.dart',
          content: 'void main() {}',
          language: 'dart',
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.content_copy), findsOneWidget);
    });
  });

  group('Explore request lifecycle', () {
    test(
      'ignores foreign and reset broadcasts, then accepts its own reply',
      () async {
        final bridge = _TestBridgeService();
        addTearDown(bridge.dispose);
        final cubit = ExploreCubit(
          bridge: bridge,
          projectPath: '/tmp/project-a',
          requestTimeout: const Duration(seconds: 1),
        );
        addTearDown(cubit.close);

        final request =
            jsonDecode(bridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        bridge.emitFileList(const FileListMessage(files: [], reset: true));
        bridge.emitFileList(
          const FileListMessage(
            files: ['wrong.txt'],
            projectPath: '/tmp/project-b',
            requestId: 'foreign',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.status, ExploreStatus.loading);

        bridge.emitFileList(
          FileListMessage(
            files: const ['lib/main.dart'],
            projectPath: '/tmp/project-a',
            requestId: request['requestId'] as String,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.status, ExploreStatus.ready);
        expect(cubit.state.allFiles, ['lib/main.dart']);
      },
    );

    test('times out and retry creates a fresh correlated request', () async {
      final bridge = _TestBridgeService();
      addTearDown(bridge.dispose);
      final cubit = ExploreCubit(
        bridge: bridge,
        projectPath: '/tmp/project',
        requestTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(cubit.close);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(cubit.state.status, ExploreStatus.error);
      expect(cubit.state.error, contains('timed out'));

      cubit.retry();
      expect(cubit.state.status, ExploreStatus.loading);
      expect(bridge.sentMessages, hasLength(2));
      final first =
          jsonDecode(bridge.sentMessages[0].toJson()) as Map<String, dynamic>;
      final second =
          jsonDecode(bridge.sentMessages[1].toJson()) as Map<String, dynamic>;
      expect(second['requestId'], isNot(first['requestId']));
    });

    test('surfaces a correlated Bridge file-list error immediately', () async {
      final bridge = _TestBridgeService();
      addTearDown(bridge.dispose);
      final cubit = ExploreCubit(
        bridge: bridge,
        projectPath: '/outside',
        requestTimeout: const Duration(seconds: 1),
      );
      addTearDown(cubit.close);
      final request =
          jsonDecode(bridge.sentMessages.single.toJson())
              as Map<String, dynamic>;

      bridge.emitFileList(
        FileListMessage(
          files: const [],
          projectPath: '/outside',
          requestId: request['requestId'] as String,
          error: 'Path not allowed',
          errorCode: 'path_not_allowed',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.status, ExploreStatus.error);
      expect(cubit.state.error, 'Path not allowed');
    });

    test(
      'old Bridge drains a closed pane reply before serving the next pane',
      () async {
        final bridge = _TestBridgeService(capabilities: const {});
        addTearDown(bridge.dispose);
        final first = ExploreCubit(
          bridge: bridge,
          projectPath: '/tmp/project-a',
          requestTimeout: const Duration(seconds: 1),
        );
        final second = ExploreCubit(
          bridge: bridge,
          projectPath: '/tmp/project-b',
          requestTimeout: const Duration(seconds: 1),
        );
        addTearDown(() async {
          if (!first.isClosed) await first.close();
          if (!second.isClosed) await second.close();
        });

        expect(bridge.sentMessages, hasLength(1));
        final firstRequest =
            jsonDecode(bridge.sentMessages.single.toJson())
                as Map<String, dynamic>;
        expect(firstRequest['projectPath'], '/tmp/project-a');

        await first.close();
        bridge.emitFileList(const FileListMessage(files: ['late-from-a.txt']));
        await Future<void>.delayed(Duration.zero);

        expect(bridge.sentMessages, hasLength(2));
        final secondRequest =
            jsonDecode(bridge.sentMessages.last.toJson())
                as Map<String, dynamic>;
        expect(secondRequest['projectPath'], '/tmp/project-b');
        expect(second.state.status, ExploreStatus.loading);
        expect(second.state.allFiles, isEmpty);

        bridge.emitFileList(
          const FileListMessage(files: ['correct-for-b.txt']),
        );
        await Future<void>.delayed(Duration.zero);

        expect(second.state.status, ExploreStatus.ready);
        expect(second.state.allFiles, ['correct-for-b.txt']);
      },
    );
  });
}
