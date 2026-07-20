import 'dart:convert';

import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

const transferId = '123e4567-e89b-12d3-a456-426614174000';
const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const etag = '"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"';

void main() {
  test('slot keeps v2 compatibility and advertises path-aware v3 results', () {
    expect(fileTransferCapability, 'file_transfer_v2');
    expect(maxFileTransferBytes, 15 * 1024 * 1024 * 1024);
    expect(fileTransferChunkBytes, 16 * 1024 * 1024);
    expect(fileTransferProtocolSlot.supportedServerMessageTypes, const [
      'file_transfer_offer_v2',
      'file_transfer_upload_ready_v2',
      'file_transfer_upload_result_v2',
      'file_transfer_upload_result_v3',
      'file_transfer_download_resumed_v2',
      'file_transfer_cancel_result_v2',
    ]);
  });

  test('decodes a strict resumable download offer', () {
    final decoded = ServerMessage.fromJson({
      'type': 'file_transfer_offer_v2',
      'transferId': transferId,
      'filename': '报告.zip',
      'mimeType': 'application/zip',
      'sizeBytes': maxFileTransferBytes,
      'downloadUrl':
          'https://mac.example/api/file-transfers/downloads/$transferId',
      'downloadToken': token,
      'etag': etag,
      'expiresAt': '2026-07-25T12:00:00.000Z',
    });

    expect(decoded, isA<FileTransferOfferMessage>());
    final offer = decoded as FileTransferOfferMessage;
    expect(offer.transferId, transferId);
    expect(offer.sizeBytes, maxFileTransferBytes);
    expect(offer.downloadToken, token);
    expect(offer.etag, etag);
  });

  test('decodes upload ready and completion tombstone result', () {
    final ready =
        ServerMessage.fromJson({
              'type': 'file_transfer_upload_ready_v2',
              'requestId': 'request-1',
              'transferId': transferId,
              'uploadUrl':
                  'https://mac.example/api/file-transfers/uploads/$transferId',
              'uploadToken': token,
              'resumeToken': token,
              'uploadOffset': 16 * 1024 * 1024,
              'sizeBytes': 32 * 1024 * 1024,
              'maxChunkSizeBytes': fileTransferChunkBytes,
              'expiresAt': '2026-07-25T12:00:00.000Z',
            })
            as FileTransferUploadReadyMessage;
    expect(ready.uploadOffset, fileTransferChunkBytes);
    expect(ready.resumeToken, token);

    final result =
        ServerMessage.fromJson({
              'type': 'file_transfer_upload_result_v2',
              'requestId': 'request-1',
              'transferId': transferId,
              'success': true,
              'filename': 'report (1).zip',
              'sizeBytes': 32 * 1024 * 1024,
            })
            as FileTransferUploadResultMessage;
    expect(result.success, isTrue);
    expect(result.filename, 'report (1).zip');
  });

  test('decodes a negotiated upload result with the saved Mac path', () {
    final result =
        ServerMessage.fromJson({
              'type': 'file_transfer_upload_result_v3',
              'requestId': 'request-1',
              'transferId': transferId,
              'success': true,
              'filename': 'report.zip',
              'sizeBytes': 32,
              'savedPath': '/Users/test/Downloads/report.zip',
            })
            as FileTransferUploadResultMessage;

    expect(result.savedPath, '/Users/test/Downloads/report.zip');
    expect(
      () => ServerMessage.fromJson({
        'type': 'file_transfer_upload_result_v3',
        'requestId': 'request-1',
        'transferId': transferId,
        'success': true,
        'filename': 'report.zip',
        'sizeBytes': 32,
      }),
      throwsFormatException,
    );
  });

  test('prepare always carries stable mobile-owned identity and secret', () {
    final json = _json(
      prepareFileTransferUpload(
        requestId: 'request-1',
        transferId: transferId,
        resumeToken: token,
        filename: 'report.zip',
        sizeBytes: maxFileTransferBytes,
      ),
    );

    expect(json, {
      'type': 'file_transfer_upload_prepare_v2',
      'requestId': 'request-1',
      'transferId': transferId,
      'resumeToken': token,
      'filename': 'report.zip',
      'sizeBytes': maxFileTransferBytes,
    });
  });

  test('receive result reports resumable byte offset without a Mac path', () {
    final json = _json(
      acknowledgeFileTransferReceive(
        transferId: transferId,
        success: false,
        receivedBytes: fileTransferChunkBytes,
        errorCode: 'insufficient_storage',
        error: 'paused',
      ),
    );

    expect(json['type'], 'file_transfer_receive_result_v2');
    expect(json['receivedBytes'], fileTransferChunkBytes);
    expect(json, isNot(contains('savedPath')));
  });

  test('download lease renewal keeps the stable token live-only', () {
    final request = _json(
      resumeFileTransferDownload(
        requestId: 'request-2',
        transferId: transferId,
        downloadToken: token,
      ),
    );
    expect(request, {
      'type': 'file_transfer_download_resume_v2',
      'requestId': 'request-2',
      'transferId': transferId,
      'downloadToken': token,
    });

    final response =
        ServerMessage.fromJson({
              'type': 'file_transfer_download_resumed_v2',
              'requestId': 'request-2',
              'transferId': transferId,
              'success': true,
              'sizeBytes': 32,
              'etag': etag,
              'expiresAt': '2026-07-26T12:00:00.000Z',
            })
            as FileTransferDownloadResumedMessage;
    expect(response.success, isTrue);
    expect(response.etag, etag);
  });

  test('cancel protocol is correlated, directional, and live-only', () {
    expect(
      _json(
        cancelFileTransfer(
          requestId: 'request-3',
          transferId: transferId,
          direction: FileTransferCancelDirection.upload,
          resumeToken: token,
        ),
      ),
      {
        'type': 'file_transfer_cancel_v2',
        'requestId': 'request-3',
        'transferId': transferId,
        'direction': 'upload',
        'resumeToken': token,
      },
    );
    expect(
      _json(
        cancelFileTransfer(
          requestId: 'request-4',
          transferId: transferId,
          direction: FileTransferCancelDirection.download,
          downloadToken: token,
        ),
      ),
      {
        'type': 'file_transfer_cancel_v2',
        'requestId': 'request-4',
        'transferId': transferId,
        'direction': 'download',
        'downloadToken': token,
      },
    );
    final result =
        ServerMessage.fromJson({
              'type': 'file_transfer_cancel_result_v2',
              'requestId': 'request-4',
              'transferId': transferId,
              'direction': 'download',
              'success': false,
              'errorCode': 'not_found',
            })
            as FileTransferCancelResultMessage;
    expect(result.direction, FileTransferCancelDirection.download);
    expect(result.errorCode, 'not_found');
    expect(
      () => cancelFileTransfer(
        requestId: 'request-5',
        transferId: transferId,
        direction: FileTransferCancelDirection.upload,
      ),
      throwsArgumentError,
    );
  });

  test('rejects oversize, malformed token, etag, and offset', () {
    Map<String, dynamic> offer() => {
      'type': 'file_transfer_offer_v2',
      'transferId': transferId,
      'filename': 'report.zip',
      'mimeType': 'application/zip',
      'sizeBytes': 1,
      'downloadUrl':
          'https://mac.example/api/file-transfers/downloads/$transferId',
      'downloadToken': token,
      'etag': etag,
      'expiresAt': '2026-07-25T12:00:00.000Z',
    };

    expect(
      () => ServerMessage.fromJson({
        ...offer(),
        'sizeBytes': maxFileTransferBytes + 1,
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({...offer(), 'downloadToken': 'short'}),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({...offer(), 'etag': 'weak'}),
      throwsFormatException,
    );
    final withoutMimeType = offer()..remove('mimeType');
    expect(
      () => ServerMessage.fromJson(withoutMimeType),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'file_transfer_upload_ready_v2',
        'requestId': 'request-1',
        'transferId': transferId,
        'uploadUrl':
            'https://mac.example/api/file-transfers/uploads/$transferId',
        'uploadToken': token,
        'resumeToken': token,
        'uploadOffset': 2,
        'sizeBytes': 1,
        'maxChunkSizeBytes': fileTransferChunkBytes,
        'expiresAt': '2026-07-25T12:00:00.000Z',
      }),
      throwsFormatException,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'file_transfer_upload_result_v2',
        'requestId': 'request-1',
        'transferId': transferId,
        'success': true,
        'sizeBytes': maxFileTransferBytes + 1,
      }),
      throwsFormatException,
    );
  });

  test('successful upload result requires a safe filename and exact size', () {
    Map<String, dynamic> result() => {
      'type': 'file_transfer_upload_result_v2',
      'requestId': 'request-1',
      'transferId': transferId,
      'success': true,
      'filename': 'report.bin',
      'sizeBytes': 1,
    };

    final withoutFilename = result()..remove('filename');
    final withoutSize = result()..remove('sizeBytes');
    expect(
      () => ServerMessage.fromJson(withoutFilename),
      throwsFormatException,
    );
    expect(() => ServerMessage.fromJson(withoutSize), throwsFormatException);
    expect(
      () => ServerMessage.fromJson({...result(), 'filename': '../report.bin'}),
      throwsFormatException,
    );
  });

  test('error text matches the Bridge 2048-character boundary', () {
    final exact = 'e' * 2048;
    final inbound =
        ServerMessage.fromJson({
              'type': 'file_transfer_upload_result_v2',
              'requestId': 'request-1',
              'transferId': transferId,
              'success': false,
              'error': exact,
            })
            as FileTransferUploadResultMessage;
    expect(inbound.error, exact);
    expect(
      _json(
        acknowledgeFileTransferReceive(
          transferId: transferId,
          success: false,
          error: exact,
        ),
      )['error'],
      exact,
    );
    expect(
      () => ServerMessage.fromJson({
        'type': 'file_transfer_upload_result_v2',
        'requestId': 'request-1',
        'transferId': transferId,
        'success': false,
        'error': '${exact}e',
      }),
      throwsFormatException,
    );
    expect(
      () => acknowledgeFileTransferReceive(
        transferId: transferId,
        success: false,
        error: '${exact}e',
      ),
      throwsArgumentError,
    );
  });

  test('every v2 server control message rejects unknown fields', () {
    final messages = <Map<String, dynamic>>[
      {
        'type': 'file_transfer_offer_v2',
        'transferId': transferId,
        'filename': 'report.zip',
        'mimeType': 'application/zip',
        'sizeBytes': 1,
        'downloadUrl':
            'https://mac.example/api/file-transfers/downloads/$transferId',
        'downloadToken': token,
        'etag': etag,
        'expiresAt': '2026-07-25T12:00:00.000Z',
      },
      {
        'type': 'file_transfer_upload_ready_v2',
        'requestId': 'request-1',
        'transferId': transferId,
        'uploadUrl':
            'https://mac.example/api/file-transfers/uploads/$transferId',
        'uploadToken': token,
        'resumeToken': token,
        'uploadOffset': 0,
        'sizeBytes': 1,
        'maxChunkSizeBytes': fileTransferChunkBytes,
        'expiresAt': '2026-07-25T12:00:00.000Z',
      },
      {
        'type': 'file_transfer_upload_result_v2',
        'requestId': 'request-1',
        'transferId': transferId,
        'success': true,
      },
      {
        'type': 'file_transfer_download_resumed_v2',
        'requestId': 'request-2',
        'transferId': transferId,
        'success': true,
        'sizeBytes': 1,
        'etag': etag,
        'expiresAt': '2026-07-25T12:00:00.000Z',
      },
      {
        'type': 'file_transfer_cancel_result_v2',
        'requestId': 'request-3',
        'transferId': transferId,
        'direction': 'download',
        'success': true,
      },
    ];
    for (final message in messages) {
      expect(
        () => ServerMessage.fromJson({...message, 'unexpected': true}),
        throwsFormatException,
        reason: '${message['type']} must remain an exact frozen shape',
      );
    }
  });
}

Map<String, dynamic> _json(ClientMessage message) =>
    jsonDecode(message.toJson()) as Map<String, dynamic>;
