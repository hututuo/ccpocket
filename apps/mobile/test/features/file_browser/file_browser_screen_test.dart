import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/file_browser/file_browser_screen.dart';
import 'package:ccpocket/features/file_browser/file_browser_service.dart';
import 'package:ccpocket/features/session_list/widgets/session_list_app_bar.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScreenBridge bridge;
  late FileBrowserService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    bridge = _ScreenBridge();
    var sequence = 0;
    service = FileBrowserService(
      bridge: bridge,
      preferences: await SharedPreferences.getInstance(),
      requestIdGenerator: () => 'screen-${++sequence}',
    );
  });

  tearDown(() async {
    service.dispose();
    await bridge.dispose();
  });

  testWidgets('old Bridge keeps the Files entry but shows an update state', (
    tester,
  ) async {
    bridge.capabilities = const <String>{};

    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();

    expect(find.text('Update the Bridge'), findsOneWidget);
    expect(bridge.sent, isEmpty);
  });

  testWidgets('an empty root set settles without a refresh loop', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();
    final request = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(
      FileBrowserRootsResultMessage(
        requestId: request['requestId'] as String,
        success: true,
        bridgeInstanceId: 'bridge-screen',
        rootSetRevision: 'empty-roots-r1',
        roots: const <FileBrowserRoot>[],
        previewMaxBytes: maxFileBrowserPreviewBytes,
        downloadMaxBytes: maxFileBrowserDownloadBytes,
        downloadAvailable: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('No locations available'), findsOneWidget);
    expect(bridge.countRequests('file_browser_roots_v1'), 1);
  });

  testWidgets('browses a root, pins folders, and queues a file download', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();

    final rootsRequest = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(
      FileBrowserRootsResultMessage(
        requestId: rootsRequest['requestId'] as String,
        success: true,
        bridgeInstanceId: 'bridge-screen',
        rootSetRevision: 'roots-screen-r1',
        roots: const <FileBrowserRoot>[
          FileBrowserRoot(rootId: 'root-home', label: 'Home', displayPath: '~'),
        ],
        previewMaxBytes: maxFileBrowserPreviewBytes,
        downloadMaxBytes: maxFileBrowserDownloadBytes,
        downloadAvailable: true,
      ),
    );
    await tester.pump();

    expect(find.text('Locations'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file_browser_root_root-home')));
    await tester.pump();

    final listRequest = bridge.take('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: listRequest['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: '',
        directoryRevision: 'directory-screen-r1',
        entries: <FileBrowserNode>[
          _directoryNode('Projects'),
          _fileNode('report.pdf'),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('file_browser_pin_button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('file_browser_node_Projects')));
    await tester.pump();
    final folderRequest = bridge.take('file_browser_list_v1');
    expect(folderRequest['relativePath'], 'Projects');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: folderRequest['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: 'Projects',
        directoryRevision: 'directory-projects-r1',
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file_browser_pin_button')));
    await tester.pump();
    expect(service.currentPins.single.relativePath, 'Projects');

    await tester.tap(find.byKey(const ValueKey('file_browser_back_button')));
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('file_browser_download_report.pdf')),
    );
    await tester.tap(
      find.byKey(const ValueKey('file_browser_download_report.pdf')),
    );
    await tester.pump();
    expect(bridge.countRequests('file_browser_download_v1'), 1);
    final downloadRequest = bridge.take('file_browser_download_v1');
    bridge.messageEvents.add(
      FileBrowserDownloadResultMessage(
        requestId: downloadRequest['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: 'report.pdf',
        transferId: 'download_123456789',
        status: 'queued',
      ),
    );
    await tester.pump();

    expect(find.text('Added to the download queue'), findsOneWidget);
  });

  testWidgets('home pane exposes Files as a first-level action', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      _localizedApp(
        Scaffold(
          body: SessionListPaneHeader(
            onTitleTap: () {},
            onOpenSettings: () {},
            onOpenFileBrowser: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('file_browser_button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file_browser_button')));
    expect(opened, isTrue);
  });

  testWidgets('an unsaved legacy connection disables folder pinning', (
    tester,
  ) async {
    bridge.logicalConnectionIdentity = null;
    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();
    final roots = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(_screenRoots(roots));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file_browser_root_root-home')));
    await tester.pump();
    final list = bridge.take('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: list['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: '',
        directoryRevision: 'legacy-r1',
      ),
    );
    await tester.pump();

    final pinButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('file_browser_pin_button')),
    );
    expect(pinButton.onPressed, isNull);
    expect(pinButton.tooltip, 'Save this Mac connection to pin folders');
  });

  testWidgets('an unsaved connection never reports a file download as queued', (
    tester,
  ) async {
    bridge.logicalConnectionIdentity = null;
    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();
    final roots = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(_screenRoots(roots));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file_browser_root_root-home')));
    await tester.pump();
    final list = bridge.take('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: list['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: '',
        directoryRevision: 'legacy-download-r1',
        entries: <FileBrowserNode>[_fileNode('report.pdf')],
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('file_browser_download_report.pdf')),
    );
    await tester.pump();

    expect(bridge.countRequests('file_browser_download_v1'), 0);
    expect(find.text('Added to the download queue'), findsNothing);
    expect(
      find.text('Save this Mac connection before downloading files'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a failed manual roots refresh keeps content and reports failure',
    (tester) async {
      await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
      await tester.pump();
      final first = bridge.take('file_browser_roots_v1');
      bridge.messageEvents.add(_screenRoots(first));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('file_browser_refresh_button')),
      );
      await tester.pump();
      final refresh = bridge.take('file_browser_roots_v1');
      bridge.messageEvents.add(
        FileBrowserRootsResultMessage(
          requestId: refresh['requestId'] as String,
          success: false,
          errorCode: 'permission_denied',
          error: 'Denied',
        ),
      );
      await tester.pump();

      expect(find.text('Home'), findsOneWidget);
      expect(find.textContaining('Operation failed'), findsOneWidget);
    },
  );

  testWidgets('only the latest preview request may push a route', (
    tester,
  ) async {
    final navigatorObserver = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      _testApp(
        service,
        const FileBrowserScreen(),
        navigatorObservers: <NavigatorObserver>[navigatorObserver],
      ),
    );
    await tester.pump();
    final roots = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(_screenRoots(roots));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file_browser_root_root-home')));
    await tester.pump();
    final list = bridge.take('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: list['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: '',
        directoryRevision: 'preview-r1',
        entries: <FileBrowserNode>[_fileNode('a.pdf'), _fileNode('b.pdf')],
      ),
    );
    await tester.pump();
    final routeCountBeforePreview = navigatorObserver.pushes.length;

    await tester.tap(find.byKey(const ValueKey('file_browser_node_a.pdf')));
    await tester.tap(find.byKey(const ValueKey('file_browser_node_b.pdf')));
    await tester.pump();
    final previewRequests = bridge.sent
        .where((message) => message['type'] == 'file_browser_preview_v1')
        .toList(growable: false);
    expect(previewRequests, hasLength(2));
    final aRequest = previewRequests.singleWhere(
      (message) => message['relativePath'] == 'a.pdf',
    );
    final bRequest = previewRequests.singleWhere(
      (message) => message['relativePath'] == 'b.pdf',
    );

    bridge.messageEvents.add(_previewResult(bRequest, 'b.pdf'));
    await tester.idle();
    expect(navigatorObserver.pushes, hasLength(routeCountBeforePreview + 1));

    bridge.messageEvents.add(_previewResult(aRequest, 'a.pdf'));
    await tester.idle();
    expect(navigatorObserver.pushes, hasLength(routeCountBeforePreview + 1));
    Navigator.of(tester.element(find.byType(FileBrowserScreen))).pop();
    await tester.idle();
  });

  testWidgets(
    'directory navigation never exposes the previous folder on error',
    (tester) async {
      await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
      await tester.pump();
      final rootsRequest = bridge.take('file_browser_roots_v1');
      bridge.messageEvents.add(_screenRoots(rootsRequest));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('file_browser_root_root-home')),
      );
      await tester.pump();
      final parentRequest = bridge.take('file_browser_list_v1');
      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: parentRequest['requestId'] as String,
          success: true,
          rootId: 'root-home',
          relativePath: '',
          directoryRevision: 'parent-r1',
          entries: <FileBrowserNode>[
            _directoryNode('Projects'),
            _fileNode('parent-only.pdf'),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('file_browser_node_Projects')),
      );
      await tester.pump();
      expect(find.text('parent-only.pdf'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      final childRequest = bridge.take('file_browser_list_v1');
      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: childRequest['requestId'] as String,
          success: false,
          errorCode: 'permission_denied',
          error: 'Denied',
        ),
      );
      await tester.pump();
      expect(find.text('Could not read this location'), findsOneWidget);
      expect(find.text('parent-only.pdf'), findsNothing);
    },
  );

  testWidgets('a machine-scope change clears a same-root-id directory', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();
    final rootsRequest = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(_screenRoots(rootsRequest));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file_browser_root_root-home')));
    await tester.pump();
    final listRequest = bridge.take('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: listRequest['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: '',
        directoryRevision: 'old-machine-r1',
        entries: <FileBrowserNode>[_fileNode('old-machine.pdf')],
      ),
    );
    await tester.pump();
    expect(find.text('old-machine.pdf'), findsOneWidget);

    bridge.isConnected = false;
    bridge.connectionEvents.add(BridgeConnectionState.disconnected);
    await tester.pump();
    bridge.logicalConnectionIdentity = 'machine:other';
    bridge.isConnected = true;
    bridge.connectionEvents.add(BridgeConnectionState.connected);
    await tester.pump();
    await tester.pump();

    final nextRootsRequest = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(
      _screenRoots(nextRootsRequest, bridgeId: 'bridge-other'),
    );
    await tester.pump();
    expect(find.text('Locations'), findsOneWidget);
    expect(find.text('old-machine.pdf'), findsNothing);
  });

  testWidgets('an invalid continuation cursor reloads the first page', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();
    final rootsRequest = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(_screenRoots(rootsRequest));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file_browser_root_root-home')));
    await tester.pump();
    final firstRequest = bridge.take('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: firstRequest['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: '',
        directoryRevision: 'directory-r1',
        entries: List<FileBrowserNode>.generate(
          8,
          (index) => _fileNode('page-one-$index.pdf'),
        ),
        nextCursor: 'cursor-expiring',
      ),
    );
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('file_browser_directory_root-home_')),
      const Offset(0, -1000),
    );
    await tester.pump();
    expect(bridge.countRequests('file_browser_list_v1'), 2);
    final cursorRequest = bridge.take('file_browser_list_v1');
    expect(cursorRequest['cursor'], 'cursor-expiring');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: cursorRequest['requestId'] as String,
        success: false,
        errorCode: 'invalid_cursor',
        error: 'Cursor expired',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(bridge.countRequests('file_browser_list_v1'), 3);
    final restartedRequest = bridge.take('file_browser_list_v1');
    expect(restartedRequest.containsKey('cursor'), isFalse);
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: restartedRequest['requestId'] as String,
        success: true,
        rootId: 'root-home',
        relativePath: '',
        directoryRevision: 'directory-r2',
        entries: <FileBrowserNode>[_fileNode('fresh-page.pdf')],
      ),
    );
    await tester.pump();
    expect(find.text('fresh-page.pdf'), findsOneWidget);
  });

  testWidgets('a stale pin remains removable after its root disappears', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(service, const FileBrowserScreen()));
    await tester.pump();
    final rootsRequest = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(_screenRoots(rootsRequest));
    await tester.pump();
    await service.togglePin(
      root: service.roots.single,
      relativePath: 'Projects',
    );

    final refresh = service.refreshRoots();
    final refreshRequest = bridge.take('file_browser_roots_v1');
    bridge.messageEvents.add(
      FileBrowserRootsResultMessage(
        requestId: refreshRequest['requestId'] as String,
        success: true,
        bridgeInstanceId: 'bridge-screen',
        rootSetRevision: 'roots-screen-r2',
        roots: const <FileBrowserRoot>[
          FileBrowserRoot(
            rootId: 'root-other',
            label: 'Other',
            displayPath: 'Other',
          ),
        ],
        previewMaxBytes: maxFileBrowserPreviewBytes,
        downloadMaxBytes: maxFileBrowserDownloadBytes,
        downloadAvailable: true,
      ),
    );
    await refresh;
    await tester.pump();
    await tester.pump();

    final unpin = find.byKey(
      const ValueKey('file_browser_unpin_root-home_Projects'),
    );
    expect(unpin, findsOneWidget);
    await tester.tap(unpin);
    await tester.pump();
    expect(service.currentPins, isEmpty);
  });

  for (final width in <double>[320, 375]) {
    testWidgets('compact $width pt home toolbar keeps Files at first level', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _localizedApp(
          Scaffold(
            body: CustomScrollView(
              slivers: [
                SessionListSliverAppBar(
                  onTitleTap: () {},
                  onDisconnect: () {},
                  onOpenArchivedSessions: () {},
                  onOpenFileBrowser: () {},
                ),
                const SliverFillRemaining(child: SizedBox.shrink()),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('file_browser_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings_button')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session_list_more_button')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('gallery_button')), findsNothing);
      expect(find.byKey(const ValueKey('disconnect_button')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('session_list_more_button')));
      await tester.pumpAndSettle();
      expect(find.text('Gallery'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
    });
  }
}

FileBrowserRootsResultMessage _screenRoots(
  Map<String, dynamic> request, {
  String bridgeId = 'bridge-screen',
}) => FileBrowserRootsResultMessage(
  requestId: request['requestId'] as String,
  success: true,
  bridgeInstanceId: bridgeId,
  rootSetRevision: 'roots-$bridgeId',
  roots: const <FileBrowserRoot>[
    FileBrowserRoot(rootId: 'root-home', label: 'Home', displayPath: '~'),
  ],
  previewMaxBytes: maxFileBrowserPreviewBytes,
  downloadMaxBytes: maxFileBrowserDownloadBytes,
  downloadAvailable: true,
);

FileBrowserPreviewResultMessage _previewResult(
  Map<String, dynamic> request,
  String filename,
) => FileBrowserPreviewResultMessage(
  requestId: request['requestId'] as String,
  success: true,
  rootId: 'root-home',
  relativePath: filename,
  relativeUrl: '/artifacts/${filename.codeUnits.join()}/preview',
  filename: filename,
  mimeType: 'application/pdf',
  sizeBytes: 1024,
  previewKind: 'pdf',
  expiresAt: '2030-01-01T00:10:00.000Z',
);

Widget _testApp(
  FileBrowserService service,
  Widget child, {
  List<NavigatorObserver> navigatorObservers = const <NavigatorObserver>[],
}) => ChangeNotifierProvider<FileBrowserService>.value(
  value: service,
  child: _localizedApp(child, navigatorObservers: navigatorObservers),
);

Widget _localizedApp(
  Widget child, {
  List<NavigatorObserver> navigatorObservers = const <NavigatorObserver>[],
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  navigatorObservers: navigatorObservers,
  home: child,
);

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
    super.didPush(route, previousRoute);
  }
}

FileBrowserNode _directoryNode(String name) => FileBrowserNode(
  name: name,
  relativePath: name,
  kind: FileBrowserNodeKind.directory,
  targetKind: null,
  isSymlink: false,
  sizeBytes: null,
  modifiedAt: '2030-01-01T00:00:00.000Z',
  mimeType: null,
  previewKind: null,
  canOpen: true,
  canPreview: false,
  canDownload: false,
  nodeRevision: 'revision-$name',
);

FileBrowserNode _fileNode(String name) => FileBrowserNode(
  name: name,
  relativePath: name,
  kind: FileBrowserNodeKind.file,
  targetKind: null,
  isSymlink: false,
  sizeBytes: 1024,
  modifiedAt: '2030-01-01T00:00:00.000Z',
  mimeType: 'application/pdf',
  previewKind: 'pdf',
  canOpen: true,
  canPreview: true,
  canDownload: true,
  nodeRevision: 'revision-$name',
);

class _ScreenBridge implements FileBrowserBridgeGateway {
  @override
  bool isConnected = true;
  @override
  String? logicalConnectionIdentity = 'machine:screen';
  @override
  String? httpBaseUrl = 'http://100.64.0.1:8765';
  @override
  Set<String> capabilities = const <String>{fileBrowserCapability};

  final StreamController<BridgeConnectionState> connectionEvents =
      StreamController<BridgeConnectionState>.broadcast();
  final StreamController<void> capabilityEvents =
      StreamController<void>.broadcast();
  final StreamController<LocalFeatureServerMessage> messageEvents =
      StreamController<LocalFeatureServerMessage>.broadcast(sync: true);
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Stream<BridgeConnectionState> get connectionStatus => connectionEvents.stream;
  @override
  Stream<void> get capabilityChanges => capabilityEvents.stream;
  @override
  Stream<LocalFeatureServerMessage> get messages => messageEvents.stream;

  @override
  void send(ClientMessage message) {
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
  }

  Map<String, dynamic> take(String type) =>
      sent.lastWhere((message) => message['type'] == type);

  int countRequests(String type) =>
      sent.where((message) => message['type'] == type).length;

  Future<void> dispose() async {
    await connectionEvents.close();
    await capabilityEvents.close();
    await messageEvents.close();
  }
}
