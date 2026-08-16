part of '../../messages.dart';

const LocalFeatureProtocolSlot fileTransferProtocolSlot =
    _FileTransferProtocolSlot();

const fileTransferCapability = 'file_transfer_v2';
const fileTransferDiagnosticReportCapability =
    'file_transfer_diagnostic_report_v1';
const fileTransferDiagnosticReportNoStepUpCapability =
    'file_transfer_diagnostic_report_no_step_up_v1';
const maxFileTransferBytes = 15 * 1024 * 1024 * 1024;
const maxDiagnosticReportBytes = 16 * 1024 * 1024;
const fileTransferChunkBytes = 16 * 1024 * 1024;
const _fileTransferMaxIdLength = 128;
const _fileTransferMaxFilenameLength = 1024;
const _fileTransferMaxUrlLength = 4096;
const _fileTransferMaxErrorLength = 2048;
const _fileTransferMaxProviderLength = 64;
const _fileTransferMaxProviderSessionIdLength = 256;
const _fileTransferMaxCodexSourceIdLength = 256;
const _fileTransferMaxBridgeInstanceIdLength = 256;
const _fileTransferMaxTimestampLength = 128;

/// The bounded metadata carried alongside a diagnostic report upload.
///
/// A typedef keeps the wire-facing API map-shaped (and therefore compatible
/// with the Bridge protocol) while giving storage and service code one shared
/// public type. Callers must still use [normalizeDiagnosticReportMetadata] to
/// obtain a validated/canonical map before persisting it.
typedef DiagnosticReportMetadata = Map<String, Object?>;

const _diagnosticReportMetadataKeys = {
  'schemaVersion',
  'reportId',
  'provider',
  'providerSessionId',
  'bridgeInstanceId',
  'codexSourceId',
  'capturedAtStart',
  'capturedAtEnd',
  'sha256',
};

/// Validates and copies the bounded diagnostic metadata contract.
///
/// The returned map contains only JSON-safe scalar values and is detached
/// from the caller's mutable map, so a queued/resumable upload cannot silently
/// change identity after its checkpoint is written.
DiagnosticReportMetadata normalizeDiagnosticReportMetadata(Object? value) {
  if (value is! Map) {
    throw const FormatException('diagnostic report metadata must be an object');
  }
  final source = <Object?, Object?>{};
  for (final entry in value.entries) {
    source[entry.key] = entry.value;
  }
  if (source.keys.any(
    (key) => key is! String || !_diagnosticReportMetadataKeys.contains(key),
  )) {
    throw const FormatException(
      'diagnostic report metadata has unknown fields',
    );
  }
  final schemaVersion = source['schemaVersion'];
  if (schemaVersion is! int || schemaVersion != 1) {
    throw const FormatException('diagnostic report schemaVersion is invalid');
  }
  final reportId = _diagnosticRequiredText(
    source['reportId'],
    'reportId',
    _fileTransferMaxIdLength,
  );
  if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(reportId)) {
    throw const FormatException('diagnostic report reportId is invalid');
  }
  final provider = _diagnosticRequiredText(
    source['provider'],
    'provider',
    _fileTransferMaxProviderLength,
  );
  final providerSessionId = _diagnosticRequiredText(
    source['providerSessionId'],
    'providerSessionId',
    _fileTransferMaxProviderSessionIdLength,
  );
  final bridgeInstanceId = _diagnosticRequiredText(
    source['bridgeInstanceId'],
    'bridgeInstanceId',
    _fileTransferMaxBridgeInstanceIdLength,
  );
  final codexSourceId = _diagnosticRequiredText(
    source['codexSourceId'],
    'codexSourceId',
    _fileTransferMaxCodexSourceIdLength,
  );
  final capturedAtStart = _diagnosticRequiredText(
    source['capturedAtStart'],
    'capturedAtStart',
    _fileTransferMaxTimestampLength,
  );
  final capturedAtEnd = _diagnosticRequiredText(
    source['capturedAtEnd'],
    'capturedAtEnd',
    _fileTransferMaxTimestampLength,
  );
  final start = DateTime.tryParse(capturedAtStart);
  final end = DateTime.tryParse(capturedAtEnd);
  if (start == null || end == null || start.isAfter(end)) {
    throw const FormatException('diagnostic report timestamps are invalid');
  }
  final sha256 = _diagnosticRequiredText(source['sha256'], 'sha256', 64);
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
    throw const FormatException('diagnostic report sha256 is invalid');
  }
  return <String, Object?>{
    'schemaVersion': 1,
    'reportId': reportId,
    'provider': provider,
    'providerSessionId': providerSessionId,
    'bridgeInstanceId': bridgeInstanceId,
    'codexSourceId': codexSourceId,
    'capturedAtStart': capturedAtStart,
    'capturedAtEnd': capturedAtEnd,
    'sha256': sha256,
  };
}

class _FileTransferProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
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
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    if (request['type'] != 'file_transfer_upload_prepare_v2') return null;
    final requestId = request['requestId'];
    if (requestId is! String ||
        requestId.isEmpty ||
        requestId.length > _fileTransferMaxIdLength) {
      return null;
    }
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: 'file_transfer_upload_prepare_v2',
      ownerSessionId: '__file_transfer__',
      requestId: requestId,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) =>
      response is FileTransferUploadReadyMessage &&
      response.requestId == request.requestId;

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) {
    final text = error.message.toLowerCase();
    return text.contains(request.requestType) ||
        (error.errorCode?.startsWith('diagnostic_') ?? false) ||
        error.errorCode == 'owner_authentication_required';
  }

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
  final String? purpose;
  final String? reportId;
  final String? error;
  final String? errorCode;

  const FileTransferUploadResultMessage({
    required this.requestId,
    required this.transferId,
    required this.success,
    this.filename,
    this.sizeBytes,
    this.savedPath,
    this.purpose,
    this.reportId,
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
      if (includesSavedPath) 'purpose',
      if (includesSavedPath) 'reportId',
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
    final purpose = includesSavedPath
        ? _fileTransferOptionalPurpose(json['purpose'])
        : null;
    final reportId = includesSavedPath
        ? _fileTransferOptionalReportId(json['reportId'])
        : null;
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
      purpose: purpose,
      reportId: reportId,
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
  FileMutationAuthorization? mutationAuthorization,
  String? purpose,
  DiagnosticReportMetadata? diagnosticReport,
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
  final normalizedReport = _normalizeUploadPurposeMetadata(
    purpose: purpose,
    diagnosticReport: diagnosticReport,
  );
  return ClientMessage._(<String, dynamic>{
    'type': 'file_transfer_upload_prepare_v2',
    'requestId': requestId,
    'transferId': transferId,
    'resumeToken': resumeToken,
    'filename': filename,
    'sizeBytes': sizeBytes,
    'mutationAuthorization': ?mutationAuthorization?.toJson(),
    'purpose': ?purpose,
    'diagnosticReport': ?normalizedReport,
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

String? _fileTransferOptionalPurpose(Object? value) {
  if (value == null) return null;
  if (value is! String || (value != 'file' && value != 'diagnostic_report')) {
    throw const FormatException('file transfer purpose is invalid');
  }
  return value;
}

String? _fileTransferOptionalReportId(Object? value) {
  if (value == null) return null;
  final reportId = _fileTransferRequiredText(
    value,
    'reportId',
    _fileTransferMaxIdLength,
  );
  if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(reportId)) {
    throw const FormatException('file transfer reportId is invalid');
  }
  return reportId;
}

DiagnosticReportMetadata? _normalizeUploadPurposeMetadata({
  required String? purpose,
  required DiagnosticReportMetadata? diagnosticReport,
}) {
  if (purpose != null && purpose != 'file' && purpose != 'diagnostic_report') {
    throw ArgumentError.value(purpose, 'purpose', 'has invalid value');
  }
  if (purpose == 'diagnostic_report') {
    if (diagnosticReport == null) {
      throw ArgumentError('diagnostic_report purpose requires metadata');
    }
    try {
      return normalizeDiagnosticReportMetadata(diagnosticReport);
    } on FormatException catch (error) {
      throw ArgumentError.value(
        diagnosticReport,
        'diagnosticReport',
        error.message,
      );
    }
  }
  if (diagnosticReport != null) {
    throw ArgumentError('diagnosticReport requires diagnostic_report purpose');
  }
  return null;
}

String _diagnosticRequiredText(Object? value, String field, int maxLength) {
  if (!_diagnosticIsBoundedText(value, maxLength)) {
    throw FormatException('diagnostic report $field is invalid');
  }
  return value as String;
}

bool _diagnosticIsBoundedText(Object? value, int maxLength) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maxLength &&
    !value.contains('\u0000');

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
