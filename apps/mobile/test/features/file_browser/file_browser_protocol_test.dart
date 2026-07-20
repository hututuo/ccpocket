import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

const _transferId = '123e4567-e89b-12d3-a456-426614174000';

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;

Map<String, dynamic> _node({
  String name = 'report.pdf',
  String relativePath = 'Documents/report.pdf',
  String kind = 'file',
  String? targetKind,
  bool isSymlink = false,
  int? sizeBytes = 1024,
  String? modifiedAt = '2026-07-20T01:02:03.000Z',
  String? mimeType = 'application/pdf',
  String? previewKind = 'web',
  bool canOpen = true,
  bool canPreview = true,
  bool canDownload = true,
  String nodeRevision = 'node-revision-1',
}) => <String, dynamic>{
  'name': name,
  'relativePath': relativePath,
  'kind': kind,
  'targetKind': ?targetKind,
  'isSymlink': isSymlink,
  'sizeBytes': ?sizeBytes,
  'modifiedAt': ?modifiedAt,
  'mimeType': ?mimeType,
  'previewKind': ?previewKind,
  'canOpen': canOpen,
  'canPreview': canPreview,
  'canDownload': canDownload,
  'nodeRevision': nodeRevision,
};

Map<String, dynamic> _rootsResult({
  List<Map<String, dynamic>>? roots,
}) => <String, dynamic>{
  'type': 'file_browser_roots_result_v1',
  'requestId': 'roots-1',
  'success': true,
  'bridgeInstanceId': 'bridge-1',
  'rootSetRevision': 'roots-revision-1',
  'roots':
      roots ??
      const [
        {'rootId': 'home', 'label': 'Home', 'displayPath': '/Users/example'},
      ],
  'previewMaxBytes': maxFileBrowserPreviewBytes,
  'downloadMaxBytes': maxFileBrowserDownloadBytes,
  'downloadAvailable': true,
};

Map<String, dynamic> _listResult({
  String relativePath = 'Documents',
  List<Map<String, dynamic>>? entries,
}) => <String, dynamic>{
  'type': 'file_browser_list_result_v1',
  'requestId': 'list-1',
  'success': true,
  'rootId': 'home',
  'relativePath': relativePath,
  'directoryRevision': 'directory-revision-1',
  'entries': entries ?? [_node()],
  'nextCursor': 'cursor-2',
};

void main() {
  group('file_browser_v1 capability and requests', () {
    test('freezes additive capability and server message surface', () {
      expect(fileBrowserCapability, 'file_browser_v1');
      expect(fileBrowserOwnerSessionId, '__file_browser__');
      expect(maxFileBrowserRoots, 32);
      expect(maxFileBrowserPageSize, 200);
      expect(defaultFileBrowserPageSize, 100);
      expect(maxFileBrowserStatItems, 32);
      expect(maxFileBrowserPreviewBytes, 2 * 1024 * 1024 * 1024);
      expect(maxFileBrowserDownloadBytes, 15 * 1024 * 1024 * 1024);
      expect(fileBrowserProtocolSlot.supportedServerMessageTypes, const [
        'file_browser_roots_result_v1',
        'file_browser_list_result_v1',
        'file_browser_stat_result_v1',
        'file_browser_preview_result_v1',
        'file_browser_download_result_v1',
      ]);

      final capabilities = _json(ClientMessage.clientCapabilities());
      final supported = (capabilities['supportedServerMessages'] as List)
          .cast<String>();
      expect(
        supported,
        containsAll(fileBrowserProtocolSlot.supportedServerMessageTypes),
      );
    });

    test('encodes every request as exact ephemeral machine-scoped RPC', () {
      final roots = requestFileBrowserRoots(requestId: 'roots-1');
      expect(roots.delivery, ClientMessageDelivery.ephemeral);
      expect(_json(roots), {
        'type': 'file_browser_roots_v1',
        'requestId': 'roots-1',
      });
      expect(LocalFeatureProtocolHost.describeRequest(roots)?.metadata, {
        'featureId': 'file_browser',
        'requestType': 'file_browser_roots_v1',
        'ownerSessionId': '__file_browser__',
        'requestId': 'roots-1',
      });

      final listWithDefaults = requestFileBrowserList(
        requestId: 'list-1',
        rootId: 'home',
      );
      expect(listWithDefaults.delivery, ClientMessageDelivery.ephemeral);
      expect(_json(listWithDefaults), {
        'type': 'file_browser_list_v1',
        'requestId': 'list-1',
        'rootId': 'home',
        'relativePath': '',
      });
      expect(
        _json(
          requestFileBrowserList(
            requestId: 'list-2',
            rootId: 'home',
            relativePath: 'Documents',
            cursor: 'cursor-1',
            pageSize: 25,
            showHidden: true,
          ),
        ),
        {
          'type': 'file_browser_list_v1',
          'requestId': 'list-2',
          'rootId': 'home',
          'relativePath': 'Documents',
          'cursor': 'cursor-1',
          'pageSize': 25,
          'showHidden': true,
        },
      );

      expect(
        _json(
          requestFileBrowserStat(
            requestId: 'stat-1',
            items: const [
              FileBrowserPathRef(rootId: 'home', relativePath: ''),
              FileBrowserPathRef(
                rootId: 'home',
                relativePath: 'Documents/report.pdf',
              ),
            ],
          ),
        ),
        {
          'type': 'file_browser_stat_v1',
          'requestId': 'stat-1',
          'items': [
            {'rootId': 'home', 'relativePath': ''},
            {'rootId': 'home', 'relativePath': 'Documents/report.pdf'},
          ],
        },
      );

      expect(
        _json(
          requestFileBrowserPreview(
            requestId: 'preview-1',
            rootId: 'home',
            relativePath: 'Documents/report.pdf',
            nodeRevision: 'node-revision-1',
          ),
        ),
        {
          'type': 'file_browser_preview_v1',
          'requestId': 'preview-1',
          'rootId': 'home',
          'relativePath': 'Documents/report.pdf',
          'nodeRevision': 'node-revision-1',
        },
      );
      expect(
        _json(
          requestFileBrowserDownload(
            requestId: 'download-1',
            rootId: 'home',
            relativePath: 'Documents/report.pdf',
          ),
        ),
        {
          'type': 'file_browser_download_v1',
          'requestId': 'download-1',
          'rootId': 'home',
          'relativePath': 'Documents/report.pdf',
        },
      );
    });

    test('rejects unsafe outbound paths and bounded collection violations', () {
      for (final path in <String>[
        '/absolute',
        'C:',
        'C:file.txt',
        'C:/absolute',
        'a//b',
        'a/./b',
        'a/../b',
        'a\\b',
        'a/\u0000b',
        'a/',
      ]) {
        expect(
          () => requestFileBrowserList(
            requestId: 'list-1',
            rootId: 'home',
            relativePath: path,
          ),
          throwsArgumentError,
          reason: 'must reject $path',
        );
      }
      expect(
        () => requestFileBrowserPreview(
          requestId: 'preview-1',
          rootId: 'home',
          relativePath: '',
        ),
        throwsArgumentError,
      );
      expect(
        () => requestFileBrowserList(
          requestId: 'list-1',
          rootId: 'home',
          pageSize: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => requestFileBrowserList(
          requestId: 'list-1',
          rootId: 'home',
          pageSize: 201,
        ),
        throwsArgumentError,
      );
      expect(
        () => requestFileBrowserStat(requestId: 'stat-1', items: const []),
        throwsArgumentError,
      );
      expect(
        () => requestFileBrowserStat(
          requestId: 'stat-1',
          items: List.generate(
            33,
            (index) =>
                FileBrowserPathRef(rootId: 'home', relativePath: 'file-$index'),
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => requestFileBrowserStat(
          requestId: 'stat-1',
          items: const [
            FileBrowserPathRef(rootId: 'home', relativePath: 'same'),
            FileBrowserPathRef(rootId: 'home', relativePath: 'same'),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('strict server result parsing', () {
    test('decodes bounded roots and an error-only failure union', () {
      final roots = ServerMessage.fromJson(_rootsResult());
      expect(roots, isA<FileBrowserRootsResultMessage>());
      final result = roots as FileBrowserRootsResultMessage;
      expect(result.sessionId, '__file_browser__');
      expect(result.bridgeInstanceId, 'bridge-1');
      expect(result.rootSetRevision, 'roots-revision-1');
      expect(result.roots.single.rootId, 'home');
      expect(result.previewMaxBytes, maxFileBrowserPreviewBytes);
      expect(result.downloadMaxBytes, maxFileBrowserDownloadBytes);
      expect(result.downloadAvailable, isTrue);

      final failure =
          ServerMessage.fromJson(const {
                'type': 'file_browser_roots_result_v1',
                'requestId': 'roots-2',
                'success': false,
              })
              as FileBrowserRootsResultMessage;
      expect(failure.success, isFalse);
      expect(failure.errorCode, isNull);
      expect(failure.error, isNull);

      final detailedFailure =
          ServerMessage.fromJson(const {
                'type': 'file_browser_list_result_v1',
                'requestId': 'list-2',
                'success': false,
                'errorCode': 'stale_cursor',
                'error': 'The directory changed',
              })
              as FileBrowserListResultMessage;
      expect(detailedFailure.errorCode, 'stale_cursor');
      expect(detailedFailure.error, 'The directory changed');
    });

    test('decodes paged nodes without imposing the 15 GiB transfer cap', () {
      final decoded =
          ServerMessage.fromJson(
                _listResult(
                  entries: [
                    _node(
                      sizeBytes: maxFileBrowserDownloadBytes + 1,
                      canDownload: false,
                    ),
                    _node(
                      name: 'Latest',
                      relativePath: 'Documents/Latest',
                      kind: 'symlink',
                      targetKind: 'directory',
                      isSymlink: true,
                      sizeBytes: null,
                      mimeType: null,
                      previewKind: null,
                      canPreview: false,
                      canDownload: false,
                      nodeRevision: 'node-revision-2',
                    ),
                  ],
                ),
              )
              as FileBrowserListResultMessage;

      expect(decoded.rootId, 'home');
      expect(decoded.relativePath, 'Documents');
      expect(decoded.entries, hasLength(2));
      expect(decoded.entries.first.kind, FileBrowserNodeKind.file);
      expect(decoded.entries.first.sizeBytes, maxFileBrowserDownloadBytes + 1);
      expect(decoded.entries.last.kind, FileBrowserNodeKind.symlink);
      expect(decoded.entries.last.targetKind, FileBrowserNodeKind.directory);
      expect(decoded.nextCursor, 'cursor-2');
    });

    test('decodes stat existence per item with no nullable-node ambiguity', () {
      final decoded =
          ServerMessage.fromJson({
                'type': 'file_browser_stat_result_v1',
                'requestId': 'stat-1',
                'success': true,
                'items': [
                  {
                    'rootId': 'home',
                    'relativePath': 'Documents/report.pdf',
                    'exists': true,
                    'node': _node(),
                  },
                  {
                    'rootId': 'home',
                    'relativePath': 'Documents/missing.pdf',
                    'exists': false,
                    'errorCode': 'not_found',
                  },
                ],
              })
              as FileBrowserStatResultMessage;

      expect(decoded.items, hasLength(2));
      expect(decoded.items.first.node?.name, 'report.pdf');
      expect(decoded.items.last.exists, isFalse);
      expect(decoded.items.last.node, isNull);
      expect(decoded.items.last.errorCode, 'not_found');
    });

    test(
      'decodes same-origin preview and queued resumable download handoff',
      () {
        final preview =
            ServerMessage.fromJson(const {
                  'type': 'file_browser_preview_result_v1',
                  'requestId': 'preview-1',
                  'success': true,
                  'rootId': 'home',
                  'relativePath': 'Documents/report.pdf',
                  'relativeUrl': '/artifacts/opaque-token?embedded=1',
                  'filename': 'report.pdf',
                  'mimeType': 'application/pdf',
                  'sizeBytes': 1024,
                  'previewKind': 'web',
                  'expiresAt': '2026-07-20T01:02:03.000Z',
                })
                as FileBrowserPreviewResultMessage;
        expect(preview.relativeUrl, '/artifacts/opaque-token?embedded=1');
        expect(preview.sizeBytes, 1024);

        final download =
            ServerMessage.fromJson(const {
                  'type': 'file_browser_download_result_v1',
                  'requestId': 'download-1',
                  'success': true,
                  'rootId': 'home',
                  'relativePath': 'Documents/report.pdf',
                  'transferId': _transferId,
                  'status': 'queued',
                })
                as FileBrowserDownloadResultMessage;
        expect(download.transferId, _transferId);
        expect(download.status, 'queued');
      },
    );

    test(
      'rejects absolute, network, path-relative, and fragmented preview URLs',
      () {
        Map<String, dynamic> preview(String relativeUrl) => <String, dynamic>{
          'type': 'file_browser_preview_result_v1',
          'requestId': 'preview-1',
          'success': true,
          'rootId': 'home',
          'relativePath': 'Documents/report.pdf',
          'relativeUrl': relativeUrl,
          'filename': 'report.pdf',
          'mimeType': 'application/pdf',
          'sizeBytes': 1024,
          'previewKind': 'web',
          'expiresAt': '2026-07-20T01:02:03.000Z',
        };

        for (final value in <String>[
          'https://evil.example/file',
          '//evil.example/file',
          'artifacts/file',
          '/artifacts/file#fragment',
          '/artifacts\\file',
          '/artifacts/\u0000file',
        ]) {
          expect(
            () => ServerMessage.fromJson(preview(value)),
            throwsFormatException,
            reason: 'must reject $value',
          );
        }
      },
    );

    test(
      'rejects unknown fields at result, root, node, and stat-item levels',
      () {
        expect(
          () => ServerMessage.fromJson({..._rootsResult(), 'future': true}),
          throwsFormatException,
        );
        expect(
          () => ServerMessage.fromJson(
            _rootsResult(
              roots: const [
                {
                  'rootId': 'home',
                  'label': 'Home',
                  'displayPath': '/Users/example',
                  'absolutePath': '/must-not-leak',
                },
              ],
            ),
          ),
          throwsFormatException,
        );
        expect(
          () => ServerMessage.fromJson(
            _listResult(
              entries: [
                {..._node(), 'future': true},
              ],
            ),
          ),
          throwsFormatException,
        );
        expect(
          () => ServerMessage.fromJson(
            _listResult(entries: [_node(isSymlink: true)]),
          ),
          throwsFormatException,
        );
        expect(
          () => ServerMessage.fromJson({
            'type': 'file_browser_stat_result_v1',
            'requestId': 'stat-1',
            'success': true,
            'items': const [
              {
                'rootId': 'home',
                'relativePath': 'missing',
                'exists': false,
                'node': null,
              },
            ],
          }),
          throwsFormatException,
        );
      },
    );

    test('enforces success/failure union, list sizes, and safe integers', () {
      expect(
        () => ServerMessage.fromJson({
          ..._rootsResult(),
          'errorCode': 'must_not_coexist',
        }),
        throwsFormatException,
      );
      expect(
        () => ServerMessage.fromJson({
          'type': 'file_browser_roots_result_v1',
          'requestId': 'roots-1',
          'success': false,
          'roots': const [],
        }),
        throwsFormatException,
      );
      expect(
        () => ServerMessage.fromJson(
          _rootsResult(
            roots: List.generate(
              33,
              (index) => {
                'rootId': 'root-$index',
                'label': 'Root $index',
                'displayPath': '/Root/$index',
              },
            ),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => ServerMessage.fromJson(
          _listResult(
            entries: List.generate(
              201,
              (index) => _node(
                name: 'file-$index',
                relativePath: 'Documents/file-$index',
                nodeRevision: 'revision-$index',
              ),
            ),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => ServerMessage.fromJson(
          _listResult(entries: [_node(sizeBytes: 9007199254740992)]),
        ),
        throwsFormatException,
      );
      expect(
        () => ServerMessage.fromJson({
          ..._rootsResult(),
          'previewMaxBytes': maxFileBrowserPreviewBytes + 1,
        }),
        throwsFormatException,
      );
    });

    test('enforces portable relative paths and UTC ISO timestamps inbound', () {
      for (final path in <String>[
        '/absolute',
        'C:',
        'C:file.txt',
        'C:/absolute',
        'a//b',
        'a/./b',
        'a/../b',
        'a\\b',
      ]) {
        expect(
          () => ServerMessage.fromJson(_listResult(relativePath: path)),
          throwsFormatException,
        );
      }
      expect(
        () => ServerMessage.fromJson(
          _listResult(
            entries: [_node(modifiedAt: '2026-07-20T01:02:03.000+00:00')],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => ServerMessage.fromJson({
          'type': 'file_browser_preview_result_v1',
          'requestId': 'preview-1',
          'success': true,
          'rootId': 'home',
          'relativePath': 'Documents/report.pdf',
          'relativeUrl': '/artifacts/token',
          'filename': 'report.pdf',
          'mimeType': 'application/pdf',
          'sizeBytes': 1,
          'previewKind': 'web',
          'expiresAt': 'not-a-time',
        }),
        throwsFormatException,
      );
    });

    test('keeps file_transfer_offer_v2 frozen without browser requestId', () {
      expect(
        () => ServerMessage.fromJson(const {
          'type': 'file_transfer_offer_v2',
          'requestId': 'download-1',
          'transferId': _transferId,
          'filename': 'report.pdf',
          'mimeType': 'application/pdf',
          'sizeBytes': 1,
          'downloadUrl': 'https://mac.example/download',
          'downloadToken': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          'etag': '"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"',
          'expiresAt': '2026-07-20T01:02:03.000Z',
        }),
        throwsFormatException,
      );
    });
  });

  test('correlates terminal results and only matching old-Bridge errors', () {
    final request = LocalFeatureProtocolHost.describeRequest(
      requestFileBrowserPreview(
        requestId: 'preview-1',
        rootId: 'home',
        relativePath: 'Documents/report.pdf',
      ),
    )!;
    final response = ServerMessage.fromJson(const {
      'type': 'file_browser_preview_result_v1',
      'requestId': 'preview-1',
      'success': false,
      'errorCode': 'preview_unavailable',
    });
    final wrongResultType = ServerMessage.fromJson(const {
      'type': 'file_browser_download_result_v1',
      'requestId': 'preview-1',
      'success': false,
    });
    final wrongRequest = ServerMessage.fromJson(const {
      'type': 'file_browser_preview_result_v1',
      'requestId': 'preview-2',
      'success': false,
    });

    expect(
      LocalFeatureProtocolHost.matchesTerminalResponse(request, response),
      isTrue,
    );
    expect(
      LocalFeatureProtocolHost.matchesTerminalResponse(
        request,
        wrongResultType,
      ),
      isFalse,
    );
    expect(
      LocalFeatureProtocolHost.matchesTerminalResponse(request, wrongRequest),
      isFalse,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unsupported_capability',
          message: 'File browser capability was not negotiated',
        ),
      ),
      isTrue,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unknown_error',
          message: 'Unknown message type: file_browser_preview_v1',
        ),
      ),
      isTrue,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'unknown_error',
          message: 'Unknown message type: file_browser_download_v1',
        ),
      ),
      isFalse,
    );
    expect(
      LocalFeatureProtocolHost.matchesRequestError(
        request,
        const ErrorMessage(
          errorCode: 'ordinary_error',
          message: 'permission denied',
        ),
      ),
      isFalse,
    );
  });
}
