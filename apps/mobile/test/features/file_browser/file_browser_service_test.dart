import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/file_browser/file_browser_service.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeFileBrowserBridge bridge;
  late SharedPreferences preferences;
  late FileBrowserService service;
  late DateTime now;
  var requestSequence = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await SharedPreferences.getInstance();
    bridge = _FakeFileBrowserBridge();
    now = DateTime.utc(2030);
    service = FileBrowserService(
      bridge: bridge,
      preferences: preferences,
      clock: () => now,
      requestIdGenerator: () => 'request-${++requestSequence}',
      requestTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    service.dispose();
    await bridge.dispose();
  });

  test(
    'old Bridge is capability-gated without sending an unknown request',
    () async {
      bridge.capabilities = const <String>{};

      await expectLater(
        service.refreshRoots(),
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.code,
            'code',
            'bridge_unsupported',
          ),
        ),
      );

      expect(bridge.sent, isEmpty);
      expect(service.availability, FileBrowserAvailability.unsupported);
    },
  );

  test(
    'loads roots, incrementally merges pages, and reuses the directory cache',
    () async {
      final rootsFuture = service.refreshRoots();
      final rootsRequest = bridge.takeRequest('file_browser_roots_v1');
      bridge.messageEvents.add(
        FileBrowserRootsResultMessage(
          requestId: rootsRequest['requestId'] as String,
          success: true,
          bridgeInstanceId: 'bridge-one',
          rootSetRevision: 'roots-r1',
          roots: const <FileBrowserRoot>[
            FileBrowserRoot(
              rootId: 'root-one',
              label: 'Home',
              displayPath: '~',
            ),
          ],
          previewMaxBytes: maxFileBrowserPreviewBytes,
          downloadMaxBytes: maxFileBrowserDownloadBytes,
          downloadAvailable: true,
        ),
      );
      await rootsFuture;

      final firstFuture = service.loadDirectory(
        rootId: 'root-one',
        relativePath: '',
      );
      final firstRequest = bridge.takeRequest('file_browser_list_v1');
      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: firstRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: '',
          directoryRevision: 'directory-r1',
          entries: <FileBrowserNode>[_fileNode('a.txt')],
          nextCursor: 'cursor-one',
        ),
      );
      final first = await firstFuture;
      expect(first.entries.map((entry) => entry.name), <String>['a.txt']);
      expect(first.hasMore, isTrue);

      final secondFuture = service.loadNextPage(first);
      final secondRequest = bridge.takeRequest('file_browser_list_v1');
      expect(secondRequest['cursor'], 'cursor-one');
      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: secondRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: '',
          directoryRevision: 'directory-r1',
          entries: <FileBrowserNode>[_directoryNode('z-folder')],
        ),
      );
      final second = await secondFuture;
      expect(second.entries.map((entry) => entry.name), <String>[
        'z-folder',
        'a.txt',
      ]);
      expect(second.hasMore, isFalse);

      final sentBeforeCacheRead = bridge.sent.length;
      final cached = await service.loadDirectory(
        rootId: 'root-one',
        relativePath: '',
      );
      expect(cached.entries, hasLength(2));
      expect(bridge.sent, hasLength(sentBeforeCacheRead));
    },
  );

  test(
    'resolves preview on the authenticated HTTP origin and queues v2 download',
    () async {
      await _loadRoots(service, bridge);
      final node = _fileNode('report.pdf');

      final previewFuture = service.preview(node, 'root-one');
      final previewRequest = bridge.takeRequest('file_browser_preview_v1');
      bridge.messageEvents.add(
        FileBrowserPreviewResultMessage(
          requestId: previewRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: 'report.pdf',
          relativeUrl: '/artifacts/token-one',
          filename: 'report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1024,
          previewKind: 'pdf',
          expiresAt: '2030-01-01T00:00:00.000Z',
        ),
      );
      final preview = await previewFuture;
      expect(
        preview.previewUri,
        Uri.parse('http://100.64.0.1:8765/artifacts/token-one'),
      );

      final downloadFuture = service.download(node, 'root-one');
      final downloadRequest = bridge.takeRequest('file_browser_download_v1');
      bridge.messageEvents.add(
        FileBrowserDownloadResultMessage(
          requestId: downloadRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: 'report.pdf',
          transferId: 'download_123456789',
          status: 'queued',
        ),
      );
      expect(await downloadFuture, 'download_123456789');
    },
  );

  test(
    'requires a stable machine identity before requesting a phone download',
    () async {
      await _loadRoots(service, bridge);
      final node = _fileNode('report.pdf');
      expect(service.canReceiveDownloads, isTrue);

      bridge.logicalConnectionIdentity = null;
      expect(service.canReceiveDownloads, isFalse);
      final sentBeforeDownload = bridge.sent.length;

      await expectLater(
        service.download(node, 'root-one'),
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.code,
            'code',
            'stable_bridge_identity_required',
          ),
        ),
      );
      expect(bridge.sent, hasLength(sentBeforeDownload));
    },
  );

  test(
    'unsupported iPhone build blocks file-browser download before request',
    () async {
      service.dispose();
      service = FileBrowserService(
        bridge: bridge,
        preferences: preferences,
        fileTransferClientSupported: false,
        clock: () => now,
        requestIdGenerator: () => 'request-${++requestSequence}',
        requestTimeout: const Duration(seconds: 2),
      );
      await _loadRoots(service, bridge);
      final sentBeforeDownload = bridge.sent.length;

      expect(service.downloadAvailable, isFalse);
      expect(service.canReceiveDownloads, isFalse);
      await expectLater(
        service.download(_fileNode('report.pdf'), 'root-one'),
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.code,
            'code',
            'download_unavailable',
          ),
        ),
      );
      expect(bridge.sent, hasLength(sentBeforeDownload));
    },
  );

  test('rejects preview URL authority changes before opening the WebView', () {
    expect(
      () => resolveFileBrowserPreviewUri(
        'http://100.64.0.1:8765',
        '//evil.example/artifacts/token',
      ),
      throwsA(
        isA<FileBrowserException>().having(
          (error) => error.code,
          'code',
          'invalid_preview_url',
        ),
      ),
    );
  });

  test(
    'pins are scoped to logical machine and Bridge installation identity',
    () async {
      await _loadRoots(service, bridge);
      const root = FileBrowserRoot(
        rootId: 'root-one',
        label: 'Home',
        displayPath: '~',
      );

      await service.togglePin(root: root, relativePath: 'Documents/Research');
      expect(service.currentPins, hasLength(1));
      expect(service.currentPins.single.label, 'Research');
      expect(service.currentPins.single.relativePath, 'Documents/Research');

      bridge.logicalConnectionIdentity = 'machine:other';
      bridge.capabilityEvents.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(service.currentPins, isEmpty);

      bridge.logicalConnectionIdentity = 'machine:one';
      bridge.capabilityEvents.add(null);
      await Future<void>.delayed(Duration.zero);
      await _loadRoots(service, bridge);
      expect(service.currentPins, hasLength(1));
    },
  );

  test(
    'correlates an old-Bridge generic unsupported error to one request',
    () async {
      final future = service.refreshRoots();
      final request = bridge.takeRequest('file_browser_roots_v1');
      bridge.messageEvents.add(
        LocalFeatureRequestErrorMessage(
          featureId: fileBrowserFeatureId,
          ownerSessionId: fileBrowserOwnerSessionId,
          requestType: 'file_browser_roots_v1',
          requestId: request['requestId'] as String,
          message: 'file_browser_roots_v1 unsupported',
          errorCode: 'unsupported_message',
        ),
      );

      await expectLater(
        future,
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.code,
            'code',
            'unsupported_message',
          ),
        ),
      );
      expect(service.availability, FileBrowserAvailability.unsupported);
    },
  );

  test(
    'normalizes a send-time disconnect and clears the pending RPC',
    () async {
      bridge.sendError = StateError('socket closed');

      await expectLater(
        service.refreshRoots(),
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.code,
            'code',
            'bridge_disconnected',
          ),
        ),
      );
      expect(service.availability, FileBrowserAvailability.error);

      bridge.sendError = null;
      final retry = service.refreshRoots();
      final request = bridge.takeRequest('file_browser_roots_v1');
      bridge.messageEvents.add(_rootsResult(request));
      await retry;
      expect(service.availability, FileBrowserAvailability.ready);
    },
  );

  test('single-flights identical roots and directory refreshes', () async {
    final firstRoots = service.refreshRoots();
    final secondRoots = service.refreshRoots();
    expect(bridge.countRequests('file_browser_roots_v1'), 1);
    final rootsRequest = bridge.takeRequest('file_browser_roots_v1');
    bridge.messageEvents.add(_rootsResult(rootsRequest));
    await Future.wait(<Future<void>>[firstRoots, secondRoots]);

    final firstDirectory = service.loadDirectory(
      rootId: 'root-one',
      relativePath: '',
      refresh: true,
    );
    final secondDirectory = service.loadDirectory(
      rootId: 'root-one',
      relativePath: '',
      refresh: true,
    );
    expect(bridge.countRequests('file_browser_list_v1'), 1);
    final listRequest = bridge.takeRequest('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: listRequest['requestId'] as String,
        success: true,
        rootId: 'root-one',
        relativePath: '',
        directoryRevision: 'directory-r1',
        entries: <FileBrowserNode>[_fileNode('one.txt')],
      ),
    );
    final snapshots = await Future.wait(<Future<FileBrowserDirectorySnapshot>>[
      firstDirectory,
      secondDirectory,
    ]);
    expect(snapshots[0].entries.single.name, 'one.txt');
    expect(snapshots[1].entries.single.name, 'one.txt');
  });

  test(
    'a newer refresh prevents an older page from replacing the cache',
    () async {
      await _loadRoots(service, bridge);
      final firstFuture = service.loadDirectory(
        rootId: 'root-one',
        relativePath: '',
      );
      final firstRequest = bridge.takeRequest('file_browser_list_v1');
      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: firstRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: '',
          directoryRevision: 'directory-r1',
          entries: <FileBrowserNode>[_fileNode('old.txt')],
          nextCursor: 'cursor-old',
        ),
      );
      final first = await firstFuture;

      final oldPageFuture = service.loadNextPage(first);
      final oldPageRequest = bridge.takeRequest('file_browser_list_v1');
      final refreshFuture = service.loadDirectory(
        rootId: 'root-one',
        relativePath: '',
        refresh: true,
      );
      final refreshRequest = bridge.takeRequest('file_browser_list_v1');
      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: refreshRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: '',
          directoryRevision: 'directory-r2',
          entries: <FileBrowserNode>[_fileNode('new.txt')],
        ),
      );
      expect((await refreshFuture).entries.single.name, 'new.txt');

      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: oldPageRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: '',
          directoryRevision: 'directory-r1',
          entries: <FileBrowserNode>[_fileNode('late.txt')],
        ),
      );
      await expectLater(
        oldPageFuture,
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.code,
            'code',
            'request_superseded',
          ),
        ),
      );

      final sentBeforeCacheRead = bridge.sent.length;
      final cached = await service.loadDirectory(
        rootId: 'root-one',
        relativePath: '',
      );
      expect(cached.entries.single.name, 'new.txt');
      expect(bridge.sent, hasLength(sentBeforeCacheRead));
    },
  );

  test(
    'capability removal fences the scope and re-enable returns to loading',
    () async {
      await _loadRoots(service, bridge);
      final originalScope = service.scopeRevision;

      bridge.capabilities = const <String>{};
      bridge.capabilityEvents.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(service.availability, FileBrowserAvailability.unsupported);
      expect(service.roots, isEmpty);
      expect(service.scopeRevision, greaterThan(originalScope));

      bridge.capabilities = const <String>{fileBrowserCapability};
      bridge.capabilityEvents.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(service.availability, FileBrowserAvailability.loading);

      final retry = service.refreshRoots();
      final request = bridge.takeRequest('file_browser_roots_v1');
      bridge.messageEvents.add(_rootsResult(request, bridgeId: 'bridge-two'));
      await retry;
      expect(service.availability, FileBrowserAvailability.ready);
    },
  );

  test('complete-directory cache stays within its total node budget', () async {
    await _loadRoots(service, bridge);
    for (var directory = 0; directory < 9; directory++) {
      final relativePath = 'folder-$directory';
      final firstFuture = service.loadDirectory(
        rootId: 'root-one',
        relativePath: relativePath,
      );
      final firstRequest = bridge.takeRequest('file_browser_list_v1');
      bridge.messageEvents.add(
        FileBrowserListResultMessage(
          requestId: firstRequest['requestId'] as String,
          success: true,
          rootId: 'root-one',
          relativePath: relativePath,
          directoryRevision: 'revision-$directory',
          entries: List<FileBrowserNode>.generate(
            200,
            (index) => _fileNode('$relativePath/file-$index.txt'),
          ),
          nextCursor: 'cursor-$directory-1',
        ),
      );
      var snapshot = await firstFuture;
      for (var page = 1; page < 3; page++) {
        final nextFuture = service.loadNextPage(snapshot);
        final nextRequest = bridge.takeRequest('file_browser_list_v1');
        bridge.messageEvents.add(
          FileBrowserListResultMessage(
            requestId: nextRequest['requestId'] as String,
            success: true,
            rootId: 'root-one',
            relativePath: relativePath,
            directoryRevision: 'revision-$directory',
            entries: List<FileBrowserNode>.generate(
              200,
              (index) =>
                  _fileNode('$relativePath/file-${page * 200 + index}.txt'),
            ),
            nextCursor: page == 1 ? 'cursor-$directory-2' : null,
          ),
        );
        snapshot = await nextFuture;
      }
      expect(snapshot.entries, hasLength(600));
    }
    expect(service.cachedDirectoryNodeCount, lessThanOrEqualTo(5000));
  });

  test('a single visible directory is capped at 5000 nodes', () async {
    await _loadRoots(service, bridge);
    final current = FileBrowserDirectorySnapshot(
      rootId: 'root-one',
      relativePath: 'large',
      directoryRevision: 'large-r1',
      entries: List<FileBrowserNode>.generate(
        4900,
        (index) =>
            _fileNode('large/file-${index.toString().padLeft(4, '0')}.txt'),
      ),
      nextCursor: 'large-cursor',
      loadedAt: now,
    );

    final nextFuture = service.loadNextPage(current);
    final request = bridge.takeRequest('file_browser_list_v1');
    bridge.messageEvents.add(
      FileBrowserListResultMessage(
        requestId: request['requestId'] as String,
        success: true,
        rootId: 'root-one',
        relativePath: 'large',
        directoryRevision: 'large-r1',
        entries: List<FileBrowserNode>.generate(
          200,
          (index) =>
              _fileNode('large/tail-${index.toString().padLeft(3, '0')}.txt'),
        ),
        nextCursor: 'must-not-be-retained',
      ),
    );

    final next = await nextFuture;
    expect(next.entries, hasLength(5000));
    expect(next.nextCursor, isNull);
    expect(next.truncated, isTrue);
  });
}

FileBrowserRootsResultMessage _rootsResult(
  Map<String, dynamic> request, {
  String bridgeId = 'bridge-one',
}) => FileBrowserRootsResultMessage(
  requestId: request['requestId'] as String,
  success: true,
  bridgeInstanceId: bridgeId,
  rootSetRevision: 'roots-$bridgeId',
  roots: const <FileBrowserRoot>[
    FileBrowserRoot(rootId: 'root-one', label: 'Home', displayPath: '~'),
  ],
  previewMaxBytes: maxFileBrowserPreviewBytes,
  downloadMaxBytes: maxFileBrowserDownloadBytes,
  downloadAvailable: true,
);

Future<void> _loadRoots(
  FileBrowserService service,
  _FakeFileBrowserBridge bridge,
) async {
  final future = service.refreshRoots();
  final request = bridge.takeRequest('file_browser_roots_v1');
  bridge.messageEvents.add(
    FileBrowserRootsResultMessage(
      requestId: request['requestId'] as String,
      success: true,
      bridgeInstanceId: 'bridge-one',
      rootSetRevision: 'roots-r1',
      roots: const <FileBrowserRoot>[
        FileBrowserRoot(rootId: 'root-one', label: 'Home', displayPath: '~'),
      ],
      previewMaxBytes: maxFileBrowserPreviewBytes,
      downloadMaxBytes: maxFileBrowserDownloadBytes,
      downloadAvailable: true,
    ),
  );
  await future;
}

FileBrowserNode _fileNode(String name) => FileBrowserNode(
  name: name,
  relativePath: name,
  kind: FileBrowserNodeKind.file,
  targetKind: null,
  isSymlink: false,
  sizeBytes: 1024,
  modifiedAt: '2030-01-01T00:00:00.000Z',
  mimeType: 'application/octet-stream',
  previewKind: 'binary',
  canOpen: true,
  canPreview: true,
  canDownload: true,
  nodeRevision: 'revision-$name',
);

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

class _FakeFileBrowserBridge implements FileBrowserBridgeGateway {
  @override
  bool isConnected = true;
  @override
  String? logicalConnectionIdentity = 'machine:one';
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
  Object? sendError;

  @override
  Stream<BridgeConnectionState> get connectionStatus => connectionEvents.stream;

  @override
  Stream<void> get capabilityChanges => capabilityEvents.stream;

  @override
  Stream<LocalFeatureServerMessage> get messages => messageEvents.stream;

  @override
  void send(ClientMessage message) {
    final error = sendError;
    if (error != null) throw error;
    sent.add(jsonDecode(message.toJson()) as Map<String, dynamic>);
  }

  int countRequests(String type) =>
      sent.where((message) => message['type'] == type).length;

  Map<String, dynamic> takeRequest(String type) {
    final request = sent.lastWhere((message) => message['type'] == type);
    return request;
  }

  Future<void> dispose() async {
    await connectionEvents.close();
    await capabilityEvents.close();
    await messageEvents.close();
  }
}
