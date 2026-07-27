import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/features/git/state/git_view_cubit.dart';
import 'package:ccpocket/features/git/state/git_status_cubit.dart';
import 'package:ccpocket/features/git/state/git_view_cache_service.dart';
import 'package:ccpocket/features/git/state/git_view_state.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';

const _sampleDiff = '''
diff --git a/lib/main.dart b/lib/main.dart
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1,4 +1,5 @@
 void main() {
-  print('goodbye');
+  print('hello');
+  print('world');
   runApp(App());
 }
''';

const _multiFileDiff = '''
diff --git a/file_a.dart b/file_a.dart
--- a/file_a.dart
+++ b/file_a.dart
@@ -1,2 +1,2 @@
-old
+new
 same
diff --git a/file_b.dart b/file_b.dart
--- a/file_b.dart
+++ b/file_b.dart
@@ -1,2 +1,3 @@
 first
+added
 last
diff --git a/file_c.dart b/file_c.dart
--- a/file_c.dart
+++ b/file_c.dart
@@ -1,2 +1,2 @@
-removed
+replaced
 end
''';

const _imageDiff = '''
diff --git a/assets/logo.png b/assets/logo.png
index 1111111..2222222 100644
Binary files a/assets/logo.png and b/assets/logo.png differ
''';

const _imageChange = DiffImageChange(
  filePath: 'assets/logo.png',
  oldSize: 1,
  newSize: 1,
  mimeType: 'image/png',
  loadable: true,
);

/// Large diff with many files for stress testing.
const _largeDiff = '''
diff --git a/a.dart b/a.dart
--- a/a.dart
+++ b/a.dart
@@ -1,1 +1,1 @@
-a
+aa
diff --git a/b.dart b/b.dart
--- a/b.dart
+++ b/b.dart
@@ -1,1 +1,1 @@
-b
+bb
diff --git a/c.dart b/c.dart
--- a/c.dart
+++ b/c.dart
@@ -1,1 +1,1 @@
-c
+cc
diff --git a/d.dart b/d.dart
--- a/d.dart
+++ b/d.dart
@@ -1,1 +1,1 @@
-d
+dd
diff --git a/e.dart b/e.dart
--- a/e.dart
+++ b/e.dart
@@ -1,1 +1,1 @@
-e
+ee
''';

/// Mock BridgeService that exposes controllable streams for diff + staging + remote.
class MockDiffBridgeService extends BridgeService {
  final _diffController = StreamController<DiffResultMessage>.broadcast();
  final _diffImageController =
      StreamController<DiffImageResultMessage>.broadcast();
  final _stageController = StreamController<GitStageResultMessage>.broadcast();
  final _unstageController =
      StreamController<GitUnstageResultMessage>.broadcast();
  final _unstageHunksController =
      StreamController<GitUnstageHunksResultMessage>.broadcast();
  final _fetchController = StreamController<GitFetchResultMessage>.broadcast();
  final _pullController = StreamController<GitPullResultMessage>.broadcast();
  final _statusController =
      StreamController<GitStatusResultMessage>.broadcast();
  final _stoppedController = StreamController<String>.broadcast();
  final _remoteStatusController =
      StreamController<GitRemoteStatusResultMessage>.broadcast();
  final _branchesController =
      StreamController<GitBranchesResultMessage>.broadcast();
  final _checkoutController =
      StreamController<GitCheckoutBranchResultMessage>.broadcast();
  final _revertFileController =
      StreamController<GitRevertFileResultMessage>.broadcast();
  final _revertHunksController =
      StreamController<GitRevertHunksResultMessage>.broadcast();
  final sentMessages = <ClientMessage>[];

  @override
  Stream<DiffResultMessage> get diffResults => _diffController.stream;
  @override
  Stream<DiffImageResultMessage> get diffImageResults =>
      _diffImageController.stream;
  @override
  Stream<GitStageResultMessage> get gitStageResults => _stageController.stream;
  @override
  Stream<GitUnstageResultMessage> get gitUnstageResults =>
      _unstageController.stream;
  @override
  Stream<GitUnstageHunksResultMessage> get gitUnstageHunksResults =>
      _unstageHunksController.stream;
  @override
  Stream<GitFetchResultMessage> get gitFetchResults => _fetchController.stream;
  @override
  Stream<GitPullResultMessage> get gitPullResults => _pullController.stream;
  @override
  Stream<GitStatusResultMessage> get gitStatusResults =>
      _statusController.stream;
  @override
  Stream<String> get stoppedSessions => _stoppedController.stream;
  @override
  Stream<GitRemoteStatusResultMessage> get gitRemoteStatusResults =>
      _remoteStatusController.stream;
  @override
  Stream<GitBranchesResultMessage> get gitBranchesResults =>
      _branchesController.stream;
  @override
  Stream<GitCheckoutBranchResultMessage> get gitCheckoutBranchResults =>
      _checkoutController.stream;
  @override
  Stream<GitRevertFileResultMessage> get gitRevertFileResults =>
      _revertFileController.stream;
  @override
  Stream<GitRevertHunksResultMessage> get gitRevertHunksResults =>
      _revertHunksController.stream;

  @override
  void send(ClientMessage message) {
    sentMessages.add(message);
  }

  void emitDiff(DiffResultMessage msg) => _diffController.add(msg);
  void emitDiffImage(DiffImageResultMessage msg) =>
      _diffImageController.add(msg);
  void emitStageResult(GitStageResultMessage msg) => _stageController.add(msg);
  void emitUnstageResult(GitUnstageResultMessage msg) =>
      _unstageController.add(msg);
  void emitUnstageHunksResult(GitUnstageHunksResultMessage msg) =>
      _unstageHunksController.add(msg);
  void emitFetchResult(GitFetchResultMessage msg) => _fetchController.add(msg);
  void emitPullResult(GitPullResultMessage msg) => _pullController.add(msg);
  void emitStopped(String sessionId) => _stoppedController.add(sessionId);
  void emitRemoteStatus(GitRemoteStatusResultMessage msg) =>
      _remoteStatusController.add(msg);
  void emitRevertFileResult(GitRevertFileResultMessage msg) =>
      _revertFileController.add(msg);
  void emitRevertHunksResult(GitRevertHunksResultMessage msg) =>
      _revertHunksController.add(msg);

  @override
  void dispose() {
    _diffController.close();
    _diffImageController.close();
    _stageController.close();
    _unstageController.close();
    _unstageHunksController.close();
    _fetchController.close();
    _pullController.close();
    _statusController.close();
    _stoppedController.close();
    _remoteStatusController.close();
    _branchesController.close();
    _checkoutController.close();
    _revertFileController.close();
    _revertHunksController.close();
  }
}

GitViewCubit _createCubit({String? initialDiff}) {
  return GitViewCubit(bridge: BridgeService(), initialDiff: initialDiff);
}

Map<String, dynamic> _messageJson(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

String _latestRequestId(
  MockDiffBridgeService bridge,
  String type, {
  String? projectPath,
}) {
  final message = bridge.sentMessages.lastWhere((message) {
    if (message.type != type) return false;
    return projectPath == null ||
        _messageJson(message)['projectPath'] == projectPath;
  });
  return _messageJson(message)['requestId'] as String;
}

Future<void> _emitImageDiff(
  MockDiffBridgeService bridge,
  String projectPath,
) async {
  bridge.emitDiff(
    DiffResultMessage(
      diff: _imageDiff,
      imageChanges: const [_imageChange],
      requestId: _latestRequestId(
        bridge,
        'get_diff',
        projectPath: projectPath,
      ),
    ),
  );
  await Future.microtask(() {});
}

void main() {
  group('GitViewCubit - initialDiff mode', () {
    test('parses initial diff on build', () {
      final cubit = _createCubit(initialDiff: _sampleDiff);
      addTearDown(cubit.close);

      expect(cubit.state.files.length, 1);
      expect(cubit.state.files.first.filePath, 'lib/main.dart');
      expect(cubit.state.loading, false);
      expect(cubit.state.error, isNull);
    });

    test('returns empty files for empty diff', () {
      final cubit = _createCubit(initialDiff: '');
      addTearDown(cubit.close);

      expect(cubit.state.files, isEmpty);
      expect(cubit.state.loading, false);
    });
  });

  group('GitViewCubit - toggleCollapse', () {
    test('adds fileIdx to collapsedFileIndices', () {
      final cubit = _createCubit(initialDiff: _multiFileDiff);
      addTearDown(cubit.close);

      cubit.toggleCollapse(0);

      expect(cubit.state.collapsedFileIndices, contains(0));
    });

    test('removes fileIdx when already collapsed', () {
      final cubit = _createCubit(initialDiff: _multiFileDiff);
      addTearDown(cubit.close);

      cubit.toggleCollapse(1);
      expect(cubit.state.collapsedFileIndices, contains(1));

      cubit.toggleCollapse(1);
      expect(cubit.state.collapsedFileIndices, isNot(contains(1)));
    });

    test('toggles multiple files independently', () {
      final cubit = _createCubit(initialDiff: _multiFileDiff);
      addTearDown(cubit.close);

      cubit.toggleCollapse(0);
      cubit.toggleCollapse(2);

      expect(cubit.state.collapsedFileIndices, {0, 2});
    });
  });

  group('GitViewCubit - default state', () {
    test('returns empty state when no params provided', () {
      final cubit = GitViewCubit(bridge: BridgeService());
      addTearDown(cubit.close);

      expect(cubit.state, const GitViewState());
      expect(cubit.state.files, isEmpty);
      expect(cubit.state.loading, false);
      expect(cubit.state.lineWrapEnabled, isTrue);
      expect(cubit.state.error, isNull);
    });
  });

  group('GitViewCubit - initialDiff edge cases', () {
    test('parses whitespace-only diff as empty', () {
      final cubit = _createCubit(initialDiff: '   \n\n  ');
      addTearDown(cubit.close);

      expect(cubit.state.files, isEmpty);
    });

    test('parses multi-file diff correctly', () {
      final cubit = _createCubit(initialDiff: _multiFileDiff);
      addTearDown(cubit.close);

      expect(cubit.state.files, hasLength(3));
      expect(cubit.state.files[0].filePath, 'file_a.dart');
      expect(cubit.state.files[1].filePath, 'file_b.dart');
      expect(cubit.state.files[2].filePath, 'file_c.dart');
    });

    test('parses large diff with many files', () {
      final cubit = _createCubit(initialDiff: _largeDiff);
      addTearDown(cubit.close);

      expect(cubit.state.files, hasLength(5));
      expect(cubit.state.loading, false);
      expect(cubit.state.error, isNull);
    });
  });

  group('GitViewCubit - projectPath mode', () {
    test('starts in loading state when projectPath provided', () {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      expect(cubit.state.loading, true);
      expect(cubit.state.files, isEmpty);
    });

    test('sends getDiff, gitFetch, and gitBranches on init', () {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      // getDiff + gitFetch + gitBranches on init
      expect(mockBridge.sentMessages, hasLength(3));
      expect(mockBridge.sentMessages[0].type, 'get_diff');
      expect(mockBridge.sentMessages[1].type, 'git_fetch');
      expect(mockBridge.sentMessages[2].type, 'git_branches');
    });

    test('updates state when diff result arrives', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _sampleDiff));
      await Future.microtask(() {});

      expect(cubit.state.loading, false);
      expect(cubit.state.files, hasLength(1));
      expect(cubit.state.error, isNull);
    });

    test('handles error in diff result', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(
        const DiffResultMessage(diff: '', error: 'git not found'),
      );
      await Future.microtask(() {});

      expect(cubit.state.loading, false);
      expect(cubit.state.error, 'git not found');
    });

    test('handles empty diff result', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: ''));
      await Future.microtask(() {});

      expect(cubit.state.loading, false);
      expect(cubit.state.files, isEmpty);
      expect(cubit.state.error, isNull);
    });

    test('handles whitespace-only diff result', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: '   \n  '));
      await Future.microtask(() {});

      expect(cubit.state.loading, false);
      expect(cubit.state.files, isEmpty);
    });
  });

  group('GitViewCubit - project crosstalk filtering', () {
    test('ignores git results stamped with another projectPath', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      cubit.pull();
      mockBridge.emitRemoteStatus(
        const GitRemoteStatusResultMessage(
          ahead: 7,
          behind: 3,
          branch: 'other',
          hasUpstream: true,
          projectPath: '/home/user/other-project',
        ),
      );
      mockBridge.emitPullResult(
        const GitPullResultMessage(
          success: false,
          error: 'merge conflict in other project',
          projectPath: '/home/user/other-project',
        ),
      );
      await Future.microtask(() {});

      expect(cubit.state.commitsAhead, 0);
      expect(cubit.state.commitsBehind, 0);
      expect(cubit.state.hasUpstream, false);
      expect(cubit.state.pulling, true);
      expect(cubit.state.error, isNull);
    });

    test('applies own-project and legacy unstamped results', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitRemoteStatus(
        const GitRemoteStatusResultMessage(
          ahead: 2,
          behind: 1,
          branch: 'main',
          hasUpstream: true,
          projectPath: '/home/user/project',
        ),
      );
      cubit.pull();
      // Old Bridges echo no projectPath; those results must still apply.
      mockBridge.emitPullResult(
        const GitPullResultMessage(success: false, error: 'conflict'),
      );
      await Future.microtask(() {});

      expect(cubit.state.commitsAhead, 2);
      expect(cubit.state.commitsBehind, 1);
      expect(cubit.state.hasUpstream, true);
      expect(cubit.state.pulling, false);
      expect(cubit.state.error, 'conflict');
    });
  });

  group('GitViewCubit - diff image correlation', () {
    test('same relative image path stays isolated between projects', () async {
      final mockBridge = MockDiffBridgeService();
      final cubitA = GitViewCubit(bridge: mockBridge, projectPath: '/repo/a');
      final cubitB = GitViewCubit(bridge: mockBridge, projectPath: '/repo/b');
      addTearDown(() async {
        await cubitA.close();
        await cubitB.close();
        mockBridge.dispose();
      });

      await _emitImageDiff(mockBridge, '/repo/a');
      await _emitImageDiff(mockBridge, '/repo/b');

      cubitA.loadImage(0);
      cubitB.loadImage(0);
      final requestAId = _latestRequestId(
        mockBridge,
        'get_diff_image',
        projectPath: '/repo/a',
      );

      mockBridge.emitDiffImage(
        DiffImageResultMessage(
          projectPath: '/repo/a',
          requestId: requestAId,
          filePath: 'assets/logo.png',
          version: 'both',
          oldBase64: base64Encode(const [1]),
          newBase64: base64Encode(const [2]),
        ),
      );
      await Future.microtask(() {});

      expect(cubitA.state.files.single.imageData?.loaded, isTrue);
      expect(cubitB.state.files.single.imageData?.loaded, isFalse);
    });

    test('late image response cannot overwrite a refreshed diff', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(bridge: mockBridge, projectPath: '/repo/a');
      addTearDown(() async {
        await cubit.close();
        mockBridge.dispose();
      });

      await _emitImageDiff(mockBridge, '/repo/a');
      cubit.loadImage(0);
      final staleImageRequestId = _latestRequestId(
        mockBridge,
        'get_diff_image',
      );

      cubit.refreshDiffOnly();
      await _emitImageDiff(mockBridge, '/repo/a');
      cubit.loadImage(0);
      final currentImageRequestId = _latestRequestId(
        mockBridge,
        'get_diff_image',
      );
      expect(currentImageRequestId, isNot(staleImageRequestId));

      mockBridge.emitDiffImage(
        DiffImageResultMessage(
          projectPath: '/repo/a',
          requestId: staleImageRequestId,
          filePath: 'assets/logo.png',
          version: 'both',
          oldBase64: base64Encode(const [3]),
          newBase64: base64Encode(const [4]),
        ),
      );
      await Future.microtask(() {});
      expect(cubit.state.files.single.imageData?.loaded, isFalse);

      mockBridge.emitDiffImage(
        DiffImageResultMessage(
          projectPath: '/repo/a',
          requestId: currentImageRequestId,
          filePath: 'assets/logo.png',
          version: 'both',
          oldBase64: base64Encode(const [5]),
          newBase64: base64Encode(const [6]),
        ),
      );
      await Future.microtask(() {});
      expect(cubit.state.files.single.imageData?.loaded, isTrue);
    });

    test('legacy unstamped image result requires one waiting project', () async {
      final mockBridge = MockDiffBridgeService();
      final cubitA = GitViewCubit(bridge: mockBridge, projectPath: '/repo/a');
      final cubitB = GitViewCubit(bridge: mockBridge, projectPath: '/repo/b');
      addTearDown(() async {
        if (!cubitA.isClosed) await cubitA.close();
        if (!cubitB.isClosed) await cubitB.close();
        mockBridge.dispose();
      });

      for (final projectPath in ['/repo/a', '/repo/b']) {
        await _emitImageDiff(mockBridge, projectPath);
      }
      cubitA.loadImage(0);
      cubitB.loadImage(0);
      expect(cubitA.state.files.single.imageData?.loaded, isFalse);
      expect(cubitB.state.files.single.imageData?.loaded, isFalse);
      expect(
        mockBridge.sentMessages.where((m) => m.type == 'get_diff_image'),
        hasLength(2),
      );

      final legacyResult = DiffImageResultMessage(
        filePath: 'assets/logo.png',
        version: 'both',
        oldBase64: base64Encode(const [7]),
        newBase64: base64Encode(const [8]),
      );
      mockBridge.emitDiffImage(legacyResult);
      await Future.microtask(() {});
      expect(cubitA.state.files.single.imageData?.loaded, isFalse);
      expect(cubitB.state.files.single.imageData?.loaded, isFalse);

      await cubitB.close();
      mockBridge.emitDiffImage(legacyResult);
      await Future.microtask(() {});
      expect(cubitA.state.files.single.imageData?.loaded, isTrue);
    });
  });

  group('GitViewCubit - staging mode', () {
    test(
      'terminal timeouts clear diff, fetch, and staging busy states',
      () async {
        final mockBridge = MockDiffBridgeService();
        final cubit = GitViewCubit(
          bridge: mockBridge,
          projectPath: '/home/user/project',
          operationTimeout: const Duration(milliseconds: 15),
        );
        addTearDown(() async {
          await cubit.close();
          mockBridge.dispose();
        });

        await Future<void>.delayed(const Duration(milliseconds: 35));
        expect(cubit.state.loading, isFalse);
        expect(cubit.state.fetching, isFalse);
        expect(cubit.state.error, contains('timed out'));

        cubit.refreshDiffOnly();
        final requestId = _latestRequestId(
          mockBridge,
          'get_diff',
          projectPath: '/home/user/project',
        );
        mockBridge.emitDiff(
          DiffResultMessage(diff: _multiFileDiff, requestId: requestId),
        );
        await Future<void>.delayed(Duration.zero);
        cubit.stageFile(0);
        expect(cubit.state.staging, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 35));
        expect(cubit.state.staging, isFalse);
        expect(cubit.state.error, contains('timed out'));
      },
    );

    test(
      'failed fetch stops without issuing a remote-status request',
      () async {
        final mockBridge = MockDiffBridgeService();
        final cubit = GitViewCubit(bridge: mockBridge, projectPath: '/outside');
        addTearDown(() async {
          await cubit.close();
          mockBridge.dispose();
        });

        mockBridge.emitFetchResult(
          const GitFetchResultMessage(
            success: false,
            projectPath: '/outside',
            error: 'Path not allowed',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state.fetching, isFalse);
        expect(cubit.state.error, 'Path not allowed');
        expect(
          mockBridge.sentMessages.where(
            (message) => message.type == 'git_remote_status',
          ),
          isEmpty,
        );
      },
    );

    test('switchMode emits viewMode change and requests staged diff', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      // Initial: getDiff + gitFetch
      final initCount = mockBridge.sentMessages.length;

      cubit.switchMode(GitViewMode.staged);

      expect(cubit.state.viewMode, GitViewMode.staged);
      expect(cubit.state.loading, isTrue);
      // Should send getDiff(staged) + gitFetch
      final newMessages = mockBridge.sentMessages.sublist(initCount);
      final getDiffMsg = newMessages.firstWhere((m) => m.type == 'get_diff');
      final json = jsonDecode(getDiffMsg.toJson()) as Map<String, dynamic>;
      expect(json['staged'], isTrue);
    });

    test('switchMode to same mode is a no-op', () {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      final initCount = mockBridge.sentMessages.length;
      cubit.switchMode(GitViewMode.unstaged); // same as default
      // Should not send additional messages
      expect(mockBridge.sentMessages.length, initCount);
    });

    test('stageFile sends git_stage with file path', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      // Simulate diff result to populate files
      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.stageFile(1); // file_b.dart
      expect(cubit.state.staging, isTrue);

      final json =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(json['type'], 'git_stage');
      expect(json['files'], ['file_b.dart']);
    });

    test('stageAll sends git_stage with all file paths', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.stageAll();
      expect(cubit.state.staging, isTrue);

      final json =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(json['type'], 'git_stage');
      expect((json['files'] as List).cast<String>().toSet(), {
        'file_a.dart',
        'file_b.dart',
        'file_c.dart',
      });
    });

    test('successful stage result triggers refresh', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.stageAll();
      mockBridge.emitStageResult(const GitStageResultMessage(success: true));
      await Future.microtask(() {});

      expect(cubit.state.staging, isFalse);
      // Should have sent a refresh getDiff
      expect(
        mockBridge.sentMessages.where((m) => m.type == 'get_diff').length,
        greaterThanOrEqualTo(2),
      );
    });

    test('failed stage result shows error', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.stageFile(0);
      mockBridge.emitStageResult(
        const GitStageResultMessage(success: false, error: 'staging failed'),
      );
      await Future.microtask(() {});

      expect(cubit.state.staging, isFalse);
      expect(cubit.state.error, 'staging failed');
    });

    test('unstageAll sends git_unstage with all file paths', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.unstageAll();
      expect(cubit.state.staging, isTrue);

      final json =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(json['type'], 'git_unstage');
      expect((json['files'] as List).cast<String>().toSet(), {
        'file_a.dart',
        'file_b.dart',
        'file_c.dart',
      });
    });

    test('revertAll sends git_revert_file with all file paths', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.revertAll();
      expect(cubit.state.staging, isTrue);

      final json =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(json['type'], 'git_revert_file');
      expect((json['files'] as List).cast<String>().toSet(), {
        'file_a.dart',
        'file_b.dart',
        'file_c.dart',
      });
    });

    test('switchMode to unstaged requests unstaged diff explicitly', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      cubit.switchMode(GitViewMode.staged);
      final countAfterStaged = mockBridge.sentMessages.length;

      cubit.switchMode(GitViewMode.unstaged);

      final newMessages = mockBridge.sentMessages.sublist(countAfterStaged);
      final getDiffMsg = newMessages.firstWhere((m) => m.type == 'get_diff');
      final json = jsonDecode(getDiffMsg.toJson()) as Map<String, dynamic>;
      expect(json['staged'], isFalse);
    });

    test('discards diff_result carrying a foreign requestId', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      // Another session's response (different requestId) must not land here.
      mockBridge.emitDiff(
        const DiffResultMessage(
          diff: _multiFileDiff,
          requestId: 'gitdiff-not-ours',
        ),
      );
      await Future.microtask(() {});
      expect(cubit.state.files, isEmpty);
      expect(cubit.state.loading, isTrue);

      // The response to our own request (echoed requestId) is applied.
      final ourRequestId =
          (jsonDecode(
                    mockBridge.sentMessages
                        .firstWhere((m) => m.type == 'get_diff')
                        .toJson(),
                  )
                  as Map<String, dynamic>)['requestId']
              as String;
      mockBridge.emitDiff(
        DiffResultMessage(diff: _multiFileDiff, requestId: ourRequestId),
      );
      await Future.microtask(() {});
      expect(cubit.state.files, hasLength(3));
      expect(cubit.state.loading, isFalse);
    });

    test('drops the superseded response after a rapid mode switch', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      String requestIdOf(ClientMessage m) =>
          (jsonDecode(m.toJson()) as Map<String, dynamic>)['requestId']
              as String;
      final firstId = requestIdOf(
        mockBridge.sentMessages.lastWhere((m) => m.type == 'get_diff'),
      );

      // User switches to staged before the unstaged response arrives.
      cubit.switchMode(GitViewMode.staged);
      final secondId = requestIdOf(
        mockBridge.sentMessages.lastWhere((m) => m.type == 'get_diff'),
      );
      expect(secondId, isNot(firstId));

      // The late unstaged response must not populate the staged view.
      mockBridge.emitDiff(
        DiffResultMessage(diff: _multiFileDiff, requestId: firstId),
      );
      await Future.microtask(() {});
      expect(cubit.state.files, isEmpty);
      expect(cubit.state.loading, isTrue);

      mockBridge.emitDiff(
        DiffResultMessage(diff: _multiFileDiff, requestId: secondId),
      );
      await Future.microtask(() {});
      expect(cubit.state.files, hasLength(3));
      expect(cubit.state.loading, isFalse);
    });

    test('accepts diff_result without requestId from an old Bridge', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});
      expect(cubit.state.files, hasLength(3));
      expect(cubit.state.loading, isFalse);
    });

    test('stageHunk sends git_stage with fingerprinted hunk', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.stageHunk(0, 0);
      final json =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(json['type'], 'git_stage');
      expect(json['hunks'], [
        {
          'file': 'file_a.dart',
          'hunkIndex': 0,
          'fingerprint': {
            'oldStart': 1,
            'oldLines': 2,
            'newStart': 1,
            'newLines': 2,
            // sha1 over "-old\n+new\n" — matches the Bridge-side contract.
            'changesHash': 'e8aeea4be273128765ff12676ba3ac941fd46a46',
          },
        },
      ]);
    });

    test('unstageHunk sends git_unstage_hunks', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.unstageHunk(0, 0);
      final json =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(json['type'], 'git_unstage_hunks');
      expect(json['hunks'], [
        {
          'file': 'file_a.dart',
          'hunkIndex': 0,
          'fingerprint': {
            'oldStart': 1,
            'oldLines': 2,
            'newStart': 1,
            'newLines': 2,
            // sha1 over "-old\n+new\n" — matches the Bridge-side contract.
            'changesHash': 'e8aeea4be273128765ff12676ba3ac941fd46a46',
          },
        },
      ]);
    });

    test('revertHunk sends git_revert_hunks', () async {
      final mockBridge = MockDiffBridgeService();
      final cubit = GitViewCubit(
        bridge: mockBridge,
        projectPath: '/home/user/project',
      );
      addTearDown(() {
        cubit.close();
        mockBridge.dispose();
      });

      mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
      await Future.microtask(() {});

      cubit.revertHunk(1, 0);
      final json =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(json['type'], 'git_revert_hunks');
      expect(json['hunks'], [
        {
          'file': 'file_b.dart',
          'hunkIndex': 0,
          'fingerprint': {
            'oldStart': 1,
            'oldLines': 2,
            'newStart': 1,
            'newLines': 3,
            // sha1 over "+added\n" — matches the Bridge-side contract.
            'changesHash': '213acdd75e7a8e7ff4d9a7b469354ba061b5304d',
          },
        },
      ]);
    });

    test(
      'successful local git operation refreshes diff without git_fetch',
      () async {
        final mockBridge = MockDiffBridgeService();
        final cubit = GitViewCubit(
          bridge: mockBridge,
          projectPath: '/home/user/project',
        );
        addTearDown(() {
          cubit.close();
          mockBridge.dispose();
        });

        mockBridge.emitDiff(const DiffResultMessage(diff: _multiFileDiff));
        await Future.microtask(() {});
        final baselineFetchCount = mockBridge.sentMessages
            .where((m) => m.type == 'git_fetch')
            .length;

        cubit.revertHunk(0, 0);
        mockBridge.emitRevertHunksResult(
          const GitRevertHunksResultMessage(success: true),
        );
        await Future.microtask(() {});

        expect(
          mockBridge.sentMessages.where((m) => m.type == 'git_fetch').length,
          baselineFetchCount,
        );
        expect(
          mockBridge.sentMessages.where((m) => m.type == 'get_diff').length,
          greaterThanOrEqualTo(2),
        );
      },
    );
  });

  group('GitViewCacheService', () {
    test('returns the same cubit for a session until stopped', () async {
      final bridge = MockDiffBridgeService();
      final gitStatusCubit = GitStatusCubit(bridge: bridge);
      final cache = GitViewCacheService(
        bridge: bridge,
        gitStatusCubit: gitStatusCubit,
      );
      addTearDown(() async {
        await cache.dispose();
        await gitStatusCubit.close();
        bridge.dispose();
      });

      final first = cache.getOrCreate(
        sessionId: 's1',
        projectPath: '/home/user/project',
      );
      final second = cache.getOrCreate(
        sessionId: 's1',
        projectPath: '/home/user/project',
      );

      expect(first.created, isTrue);
      expect(second.created, isFalse);
      expect(identical(first.cubit, second.cubit), isTrue);

      bridge.emitStopped('s1');
      await Future.microtask(() {});

      final third = cache.getOrCreate(
        sessionId: 's1',
        projectPath: '/home/user/project',
      );
      expect(third.created, isTrue);
      expect(identical(first.cubit, third.cubit), isFalse);
    });

    test('refreshIfPresent refreshes cached diff only', () {
      final bridge = MockDiffBridgeService();
      final gitStatusCubit = GitStatusCubit(bridge: bridge);
      final cache = GitViewCacheService(
        bridge: bridge,
        gitStatusCubit: gitStatusCubit,
      );
      addTearDown(() async {
        await cache.dispose();
        await gitStatusCubit.close();
        bridge.dispose();
      });

      cache.getOrCreate(sessionId: 's1', projectPath: '/home/user/project');
      final initialFetchCount = bridge.sentMessages
          .where((m) => m.type == 'git_fetch')
          .length;
      cache.refreshIfPresent('s1');

      expect(
        bridge.sentMessages.where((m) => m.type == 'get_diff').length,
        greaterThanOrEqualTo(2),
      );
      expect(
        bridge.sentMessages.where((m) => m.type == 'git_fetch').length,
        initialFetchCount,
      );
      expect(
        bridge.sentMessages.where((m) => m.type == 'git_status').length,
        greaterThanOrEqualTo(1),
      );
    });
  });
}
