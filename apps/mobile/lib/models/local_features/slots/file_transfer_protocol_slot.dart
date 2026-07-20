part of '../../messages.dart';

const LocalFeatureProtocolSlot fileTransferProtocolSlot =
    _FileTransferProtocolSlot();

const fileTransferCapability = 'file_transfer_v2';
const maxFileTransferBytes = 15 * 1024 * 1024 * 1024;
const fileTransferChunkBytes = 16 * 1024 * 1024;
const _fileTransferMaxIdLength = 128;
const _fileTransferMaxFilenameLength = 1024;
const _fileTransferMaxUrlLength = 4096;
const _fileTransferMaxErrorLength = 2048;

class _FileTransferProtocolSlot implements LocalFeatureProtocolSlot {
  const _FileTransferProtocolSlot();

  @override
  String get featureId => 'file_transfer';

  @override
  List<String> get supportedServerMessageTypes => const [
    'file_transfer_offer_v2',
    'file_transfer_upload_ready_v2',
    'file_transfer_upload_result_v2',
    'file_transfer_upload_result_v3',
    'file_transfer_download_resumed_v2',
    'file_transfer_cancel_result_v2',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => switch (json['type']) {
    'file_transfer_offer_v2' => FileTransferOfferMessage.fromJson(json),
    'file_transfer_upload_ready_v2' => FileTransferUploadReadyMessage.fromJson(
      json,
    ),
    'file_transfer_upload_result_v2' =>
      FileTransferUploadResultMessage.fromJson(json),
    'file_transfer_upload_result_v3' =>
      FileTransferUploadResultMessage.fromJson(json),
    'file_transfer_download_resumed_v2' =>
      FileTransferDownloadResumedMessage.fromJson(json),
    'file_transfer_cancel_result_v2' =>
      FileTransferCancelResultMessage.fromJson(json),
    _ => null,
  };
}

enum FileTransferCancelDirection { upload, download }

class FileTransferCancelResultMessage implements LocalFeatureTransientMessage {
  final String requestId;
  final String transferId;
  final FileTransferCancelDirection direction;
  final bool success;
  final String? error;
  final String? errorCode;

  const FileTransferCancelResultMessage({
    required this.requestId,
    required this.transferId,
    required this.direction,
    required this.success,
    this.error,
    this.errorCode,
  });

  @override
  String get featureId => 'file_transfer';

  @override
  String? get sessionId => null;

  factory FileTransferCancelResultMessage.fromJson(Map<String, dynamic> json) {
    _fileTransferRequireExactKeys(json, const {
      'type',
      'requestId',
      'transferId',
      'direction',
      'success',
      'error',
      'errorCode',
    });
    final success = json['success'];
    if (success is! bool) {
      throw const FormatException('file transfer cancel success must be bool');
    }
    return FileTransferCancelResultMessage(
      requestId: _fileTransferRequiredText(
        json['requestId'],
        'requestId',
        _fileTransferMaxIdLength,
      ),
      transferId: _fileTransferRequiredTransferId(json['transferId']),
      direction: switch (json['direction']) {
        'upload' => FileTransferCancelDirection.upload,
        'download' => FileTransferCancelDirection.download,
        _ => throw const FormatException(
          'file transfer cancel direction is invalid',
        ),
      },
      success: success,
      error: _fileTransferOptionalText(
        json['error'],
        'error',
        _fileTransferMaxErrorLength,
      ),
      errorCode: _fileTransferOptionalText(
        json['errorCode'],
        'errorCode',
        _fileTransferMaxIdLength,
      ),
    );
  }
}

class FileTransferDownloadResumedMessage
    implements LocalFeatureTransientMessage {
  final String requestId;
  final String transferId;
  final bool success;
  final int? sizeBytes;
  final String? etag;
  final String? expiresAt;
  final String? error;
  final String? errorCode;

  const FileTransferDownloadResumedMessage({
    required this.requestId,
    required this.transferId,
    required this.success,
    this.sizeBytes,
    this.etag,
    this.expiresAt,
    this.error,
    this.errorCode,
  });

  @override
  String get featureId => 'file_transfer';

  @override
  String? get sessionId => null;

  factory FileTransferDownloadResumedMessage.fromJson(
    Map<String, dynamic> json,
  ) {
    _fileTransferRequireExactKeys(json, const {
      'type',
      'requestId',
      'transferId',
      'success',
      'sizeBytes',
      'etag',
      'expiresAt',
      'error',
      'errorCode',
    });
    final success = json['success'];
    if (success is! bool) {
      throw const FormatException('download resume success must be bool');
    }
    final sizeBytes = json['sizeBytes'] == null
        ? null
        : _fileTransferRequiredSize(json['sizeBytes']);
    final etag = json['etag'] == null
        ? null
        : _fileTransferRequiredEtag(json['etag']);
    final expiresAt = json['expiresAt'] == null
        ? null
        : _fileTransferRequiredTimestamp(json['expiresAt']);
    if (success && (sizeBytes == null || etag == null || expiresAt == null)) {
      throw const FormatException('successful download resume is incomplete');
    }
    return FileTransferDownloadResumedMessage(
      requestId: _fileTransferRequiredText(
        json['requestId'],
        'requestId',
        _fileTransferMaxIdLength,
      ),
      transferId: _fileTransferRequiredTransferId(json['transferId']),
      success: success,
      sizeBytes: sizeBytes,
      etag: etag,
      expiresAt: expiresAt,
      error: _fileTransferOptionalText(
        json['error'],
        'error',
        _fileTransferMaxErrorLength,
      ),
      errorCode: _fileTransferOptionalText(
        json['errorCode'],
        'errorCode',
        _fileTransferMaxIdLength,
      ),
    );
  }
}

class FileTransferOfferMessage implements LocalFeatureTransientMessage {
  final String transferId;
  final String filename;
  final String mimeType;
  final int sizeBytes;
  final String downloadUrl;
  final String downloadToken;
  final String etag;
  final String expiresAt;

  const FileTransferOfferMessage({
    required this.transferId,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    required this.downloadUrl,
    required this.downloadToken,
    required this.etag,
    required this.expiresAt,
  });

  @override
  String get featureId => 'file_transfer';

  @override
  String? get sessionId => null;

  factory FileTransferOfferMessage.fromJson(Map<String, dynamic> json) {
    _fileTransferRequireExactKeys(json, const {
      'type',
      'transferId',
      'filename',
      'mimeType',
      'sizeBytes',
      'downloadUrl',
      'downloadToken',
      'etag',
      'expiresAt',
    });
    return FileTransferOfferMessage(
      transferId: _fileTransferRequiredTransferId(json['transferId']),
      filename: _fileTransferRequiredText(
        json['filename'],
        'filename',
        _fileTransferMaxFilenameLength,
      ),
      mimeType: _fileTransferRequiredText(json['mimeType'], 'mimeType', 256),
      sizeBytes: _fileTransferRequiredSize(json['sizeBytes']),
      downloadUrl: _fileTransferRequiredText(
        json['downloadUrl'],
        'downloadUrl',
        _fileTransferMaxUrlLength,
      ),
      downloadToken: _fileTransferRequiredToken(
        json['downloadToken'],
        'downloadToken',
      ),
      etag: _fileTransferRequiredEtag(json['etag']),
      expiresAt: _fileTransferRequiredTimestamp(json['expiresAt']),
    );
  }
}

class FileTransferUploadReadyMessage implements LocalFeatureTransientMessage {
  final String requestId;
  final String transferId;
  final String uploadUrl;
  final String uploadToken;
  final String resumeToken;
  final int uploadOffset;
  final int sizeBytes;
  final int maxChunkSizeBytes;
  final String expiresAt;

  const FileTransferUploadReadyMessage({
    required this.requestId,
    required this.transferId,
    required this.uploadUrl,
    required this.uploadToken,
    required this.resumeToken,
    required this.uploadOffset,
    required this.sizeBytes,
    required this.maxChunkSizeBytes,
    required this.expiresAt,
  });

  @override
  String get featureId => 'file_transfer';

  @override
  String? get sessionId => null;

  factory FileTransferUploadReadyMessage.fromJson(Map<String, dynamic> json) {
    _fileTransferRequireExactKeys(json, const {
      'type',
      'requestId',
      'transferId',
      'uploadUrl',
      'uploadToken',
      'resumeToken',
      'uploadOffset',
      'sizeBytes',
      'maxChunkSizeBytes',
      'expiresAt',
    });
    final requestId = _fileTransferRequiredText(
      json['requestId'],
      'requestId',
      _fileTransferMaxIdLength,
    );
    final transferId = _fileTransferRequiredTransferId(json['transferId']);
    final uploadOffset = _fileTransferRequiredSize(json['uploadOffset']);
    final sizeBytes = _fileTransferRequiredSize(json['sizeBytes']);
    if (uploadOffset > sizeBytes) {
      throw const FormatException('file transfer uploadOffset exceeds size');
    }
    return FileTransferUploadReadyMessage(
      requestId: requestId,
      transferId: transferId,
      uploadUrl: _fileTransferRequiredText(
        json['uploadUrl'],
        'uploadUrl',
        _fileTransferMaxUrlLength,
      ),
      uploadToken: _fileTransferRequiredToken(
        json['uploadToken'],
        'uploadToken',
      ),
      resumeToken: _fileTransferRequiredToken(
        json['resumeToken'],
        'resumeToken',
      ),
      uploadOffset: uploadOffset,
      sizeBytes: sizeBytes,
      maxChunkSizeBytes: _fileTransferRequiredChunkSize(
        json['maxChunkSizeBytes'],
      ),
      expiresAt: _fileTransferRequiredTimestamp(json['expiresAt']),
    );
  }
}

class FileTransferUploadResultMessage implements LocalFeatureTransientMessage {
  final String requestId;
  final String transferId;
  final bool success;
  final String? filename;
  final int? sizeBytes;
  final String? savedPath;
  final String? error;
  final String? errorCode;

  const FileTransferUploadResultMessage({
    required this.requestId,
    required this.transferId,
    required this.success,
    this.filename,
    this.sizeBytes,
    this.savedPath,
    this.error,
    this.errorCode,
  });

  @override
  String get featureId => 'file_transfer';

  @override
  String? get sessionId => null;

  factory FileTransferUploadResultMessage.fromJson(Map<String, dynamic> json) {
    final includesSavedPath = json['type'] == 'file_transfer_upload_result_v3';
    _fileTransferRequireExactKeys(json, {
      'type',
      'requestId',
      'transferId',
      'success',
      'filename',
      'sizeBytes',
      if (includesSavedPath) 'savedPath',
      'error',
      'errorCode',
    });
    final success = json['success'];
    if (success is! bool) {
      throw const FormatException('file transfer success must be a bool');
    }
    final rawSize = json['sizeBytes'];
    final sizeBytes = rawSize == null
        ? null
        : _fileTransferRequiredSize(rawSize);
    final filename = success
        ? _fileTransferRequiredFilename(json['filename'])
        : _fileTransferOptionalText(
            json['filename'],
            'filename',
            _fileTransferMaxFilenameLength,
          );
    if (success && sizeBytes == null) {
      throw const FormatException(
        'successful file transfer result requires sizeBytes',
      );
    }
    final savedPath = includesSavedPath
        ? _fileTransferOptionalText(
            json['savedPath'],
            'savedPath',
            _fileTransferMaxUrlLength,
          )
        : null;
    if (success && includesSavedPath && savedPath == null) {
      throw const FormatException(
        'successful v3 file transfer result requires savedPath',
      );
    }
    return FileTransferUploadResultMessage(
      requestId: _fileTransferRequiredText(
        json['requestId'],
        'requestId',
        _fileTransferMaxIdLength,
      ),
      transferId: _fileTransferRequiredTransferId(json['transferId']),
      success: success,
      filename: filename,
      sizeBytes: sizeBytes,
      savedPath: savedPath,
      error: _fileTransferOptionalText(
        json['error'],
        'error',
        _fileTransferMaxErrorLength,
      ),
      errorCode: _fileTransferOptionalText(
        json['errorCode'],
        'errorCode',
        _fileTransferMaxIdLength,
      ),
    );
  }
}

ClientMessage prepareFileTransferUpload({
  required String requestId,
  required String transferId,
  required String resumeToken,
  required String filename,
  required int sizeBytes,
}) {
  _fileTransferRequireOutboundText(
    requestId,
    'requestId',
    _fileTransferMaxIdLength,
  );
  _fileTransferRequireOutboundText(
    filename,
    'filename',
    _fileTransferMaxFilenameLength,
  );
  if (sizeBytes < 0 || sizeBytes > maxFileTransferBytes) {
    throw ArgumentError.value(sizeBytes, 'sizeBytes', 'must be in range');
  }
  _fileTransferRequireOutboundTransferId(transferId);
  _fileTransferRequireOutboundToken(resumeToken, 'resumeToken');
  return ClientMessage._(<String, dynamic>{
    'type': 'file_transfer_upload_prepare_v2',
    'requestId': requestId,
    'transferId': transferId,
    'resumeToken': resumeToken,
    'filename': filename,
    'sizeBytes': sizeBytes,
  }, delivery: ClientMessageDelivery.ephemeral);
}

ClientMessage acknowledgeFileTransferReceive({
  required String transferId,
  required bool success,
  String? savedFilename,
  String? error,
  String? errorCode,
  int? receivedBytes,
}) {
  _fileTransferRequireOutboundTransferId(transferId);
  if (savedFilename != null) {
    _fileTransferRequireOutboundText(
      savedFilename,
      'savedFilename',
      _fileTransferMaxFilenameLength,
    );
  }
  if (error != null && error.length > _fileTransferMaxErrorLength) {
    throw ArgumentError.value(error, 'error', 'must be bounded');
  }
  if (errorCode != null) {
    _fileTransferRequireOutboundText(
      errorCode,
      'errorCode',
      _fileTransferMaxIdLength,
    );
  }
  if (receivedBytes != null &&
      (receivedBytes < 0 || receivedBytes > maxFileTransferBytes)) {
    throw ArgumentError.value(receivedBytes, 'receivedBytes', 'out of range');
  }
  return ClientMessage._(<String, dynamic>{
    'type': 'file_transfer_receive_result_v2',
    'transferId': transferId,
    'success': success,
    'savedFilename': ?savedFilename,
    'error': ?error,
    'errorCode': ?errorCode,
    'receivedBytes': ?receivedBytes,
  }, delivery: ClientMessageDelivery.ephemeral);
}

ClientMessage resumeFileTransferDownload({
  required String requestId,
  required String transferId,
  required String downloadToken,
}) {
  _fileTransferRequireOutboundText(
    requestId,
    'requestId',
    _fileTransferMaxIdLength,
  );
  _fileTransferRequireOutboundTransferId(transferId);
  _fileTransferRequireOutboundToken(downloadToken, 'downloadToken');
  return ClientMessage._(<String, dynamic>{
    'type': 'file_transfer_download_resume_v2',
    'requestId': requestId,
    'transferId': transferId,
    'downloadToken': downloadToken,
  }, delivery: ClientMessageDelivery.ephemeral);
}

ClientMessage cancelFileTransfer({
  required String requestId,
  required String transferId,
  required FileTransferCancelDirection direction,
  String? resumeToken,
  String? downloadToken,
}) {
  _fileTransferRequireOutboundText(
    requestId,
    'requestId',
    _fileTransferMaxIdLength,
  );
  _fileTransferRequireOutboundTransferId(transferId);
  switch (direction) {
    case FileTransferCancelDirection.upload:
      if (resumeToken == null || downloadToken != null) {
        throw ArgumentError('upload cancellation requires only a resumeToken');
      }
      _fileTransferRequireOutboundToken(resumeToken, 'resumeToken');
    case FileTransferCancelDirection.download:
      if (resumeToken != null) {
        throw ArgumentError(
          'download cancellation cannot include a resumeToken',
        );
      }
      if (downloadToken != null) {
        _fileTransferRequireOutboundToken(downloadToken, 'downloadToken');
      }
  }
  return ClientMessage._(<String, dynamic>{
    'type': 'file_transfer_cancel_v2',
    'requestId': requestId,
    'transferId': transferId,
    'direction': direction.name,
    'resumeToken': ?resumeToken,
    'downloadToken': ?downloadToken,
  }, delivery: ClientMessageDelivery.ephemeral);
}

String _fileTransferRequiredText(Object? value, String field, int maxLength) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maxLength ||
      value.contains('\u0000')) {
    throw FormatException('file transfer $field is invalid');
  }
  return value;
}

void _fileTransferRequireExactKeys(
  Map<String, dynamic> json,
  Set<String> allowed,
) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('file transfer message has unknown field $key');
    }
  }
}

String? _fileTransferOptionalText(Object? value, String field, int maxLength) {
  if (value == null) return null;
  return _fileTransferRequiredText(value, field, maxLength);
}

String _fileTransferRequiredFilename(Object? value) {
  final filename = _fileTransferRequiredText(
    value,
    'filename',
    _fileTransferMaxFilenameLength,
  );
  if (filename == '.' ||
      filename == '..' ||
      filename.contains('/') ||
      filename.contains('\\') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(filename)) {
    throw const FormatException('file transfer filename is invalid');
  }
  return filename;
}

int _fileTransferRequiredSize(Object? value) {
  if (value is! int || value < 0 || value > maxFileTransferBytes) {
    throw const FormatException('file transfer sizeBytes is invalid');
  }
  return value;
}

int _fileTransferRequiredChunkSize(Object? value) {
  if (value is! int || value <= 0 || value > fileTransferChunkBytes) {
    throw const FormatException('file transfer maxChunkSizeBytes is invalid');
  }
  return value;
}

String _fileTransferRequiredTransferId(Object? value) {
  final text = _fileTransferRequiredText(
    value,
    'transferId',
    _fileTransferMaxIdLength,
  );
  if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(text)) {
    throw const FormatException('file transfer transferId is invalid');
  }
  return text;
}

String _fileTransferRequiredToken(Object? value, String field) {
  final text = _fileTransferRequiredText(value, field, 43);
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text)) {
    throw FormatException('file transfer $field is invalid');
  }
  return text;
}

String _fileTransferRequiredEtag(Object? value) {
  final text = _fileTransferRequiredText(value, 'etag', 34);
  if (!RegExp(r'^"[A-Za-z0-9_-]{32}"$').hasMatch(text)) {
    throw const FormatException('file transfer etag is invalid');
  }
  return text;
}

void _fileTransferRequireOutboundTransferId(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'transferId', 'has invalid format');
  }
}

void _fileTransferRequireOutboundToken(String value, String field) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    throw ArgumentError.value(value, field, 'has invalid format');
  }
}

String _fileTransferRequiredTimestamp(Object? value) {
  final timestamp = _fileTransferRequiredText(value, 'expiresAt', 128);
  if (DateTime.tryParse(timestamp) == null) {
    throw const FormatException('file transfer expiresAt is invalid');
  }
  return timestamp;
}

void _fileTransferRequireOutboundText(
  String value,
  String field,
  int maxLength,
) {
  if (value.trim().isEmpty ||
      value.length > maxLength ||
      value.contains('\u0000')) {
    throw ArgumentError.value(value, field, 'must be non-empty and bounded');
  }
}
