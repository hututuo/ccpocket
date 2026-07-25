part of '../../messages.dart';

const String fileBrowserCapability = 'file_browser_v1';
const String fileMutationAuthCapability = 'file_mutation_auth_v1';
const String fileTransferUploadAuthCapability =
    'file_transfer_upload_auth_v1';
const String fileBrowserFeatureId = 'file_browser';
const String fileBrowserOwnerSessionId = '__file_browser__';

const int maxFileBrowserRoots = 32;
const int maxFileBrowserPageSize = 200;
const int defaultFileBrowserPageSize = 100;
const int maxFileBrowserStatItems = 32;
const int maxFileBrowserPreviewBytes = 2 * 1024 * 1024 * 1024;
const int maxFileBrowserDownloadBytes = 15 * 1024 * 1024 * 1024;

const int _fileBrowserMaxRequestIdLength = 128;
const int _fileBrowserMaxRootIdLength = 128;
const int _fileBrowserMaxRevisionLength = 256;
const int _fileBrowserMaxNameLength = 1024;
const int _fileBrowserMaxPathLength = 4096;
const int _fileBrowserMaxRelativeUrlLength = 8192;
const int _fileBrowserMaxCursorLength = 2048;
const int _fileBrowserMaxMimeTypeLength = 256;
const int _fileBrowserMaxKindLength = 128;
const int _fileBrowserMaxErrorCodeLength = 128;
const int _fileBrowserMaxErrorLength = 2048;
const int _fileBrowserMaxSafeInteger = 9007199254740991;
const int _fileMutationMaxDeviceIdLength = 128;
const int _fileMutationMaxPublicKeyLength = 256;
const int _fileMutationMaxPasswordLength = 256;
const int _fileMutationMaxChallengeIdLength = 128;
const int _fileMutationMaxChallengePayloadLength = 4096;
const int _fileMutationMaxSignatureLength = 256;
const int _fileMutationMaxFilenameLength = 255;

const LocalFeatureProtocolSlot fileBrowserProtocolSlot =
    _FileBrowserProtocolSlot();

class _FileBrowserProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _FileBrowserProtocolSlot();

  static const requestTypes = <String>{
    'file_browser_roots_v1',
    'file_browser_list_v1',
    'file_browser_stat_v1',
    'file_browser_preview_v1',
    'file_browser_download_v1',
    'file_mutation_auth_state_v1',
    'file_mutation_auth_challenge_v1',
    'file_mutation_auth_enroll_v1',
  };

  @override
  String get featureId => fileBrowserFeatureId;

  @override
  List<String> get supportedServerMessageTypes => const [
    'file_browser_roots_result_v1',
    'file_browser_list_result_v1',
    'file_browser_stat_result_v1',
    'file_browser_preview_result_v1',
    'file_browser_download_result_v1',
    'file_mutation_auth_result_v1',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => switch (json['type']) {
    'file_browser_roots_result_v1' => FileBrowserRootsResultMessage.fromJson(
      json,
    ),
    'file_browser_list_result_v1' => FileBrowserListResultMessage.fromJson(
      json,
    ),
    'file_browser_stat_result_v1' => FileBrowserStatResultMessage.fromJson(
      json,
    ),
    'file_browser_preview_result_v1' =>
      FileBrowserPreviewResultMessage.fromJson(json),
    'file_browser_download_result_v1' =>
      FileBrowserDownloadResultMessage.fromJson(json),
    'file_mutation_auth_result_v1' =>
      FileMutationAuthResultMessage.fromJson(json),
    _ => null,
  };

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    final requestId = request['requestId'];
    if (type is! String ||
        !requestTypes.contains(type) ||
        !_fileBrowserIsBoundedIdentifier(
          requestId,
          _fileBrowserMaxRequestIdLength,
        )) {
      return null;
    }
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: type,
      ownerSessionId: fileBrowserOwnerSessionId,
      requestId: requestId as String,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) {
    if (response is! FileBrowserResultMessage ||
        response.requestId != request.requestId) {
      return false;
    }
    return switch (request.requestType) {
      'file_browser_roots_v1' => response is FileBrowserRootsResultMessage,
      'file_browser_list_v1' => response is FileBrowserListResultMessage,
      'file_browser_stat_v1' => response is FileBrowserStatResultMessage,
      'file_browser_preview_v1' => response is FileBrowserPreviewResultMessage,
      'file_browser_download_v1' =>
        response is FileBrowserDownloadResultMessage,
      'file_mutation_auth_state_v1' =>
        response is FileMutationAuthResultMessage &&
            (!response.success ||
                response.event == FileMutationAuthEvent.state),
      'file_mutation_auth_challenge_v1' =>
        response is FileMutationAuthResultMessage &&
            (!response.success ||
                response.event == FileMutationAuthEvent.challenge),
      'file_mutation_auth_enroll_v1' =>
        response is FileMutationAuthResultMessage &&
            (!response.success ||
                response.event == FileMutationAuthEvent.enrolled),
      _ => false,
    };
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) {
    if (error.errorCode == 'unsupported_capability' &&
        error.message == 'File browser capability was not negotiated') {
      return true;
    }
    final message = error.message.toLowerCase();
    return message.contains(request.requestType.toLowerCase()) &&
        RegExp(
          r'\b(unknown|unsupported|unrecognized)\b|not supported|invalid message type',
        ).hasMatch(message);
  }
}

enum FileBrowserNodeKind {
  file('file'),
  directory('directory'),
  symlink('symlink'),
  other('other');

  final String wireValue;
  const FileBrowserNodeKind(this.wireValue);

  static FileBrowserNodeKind parse(Object? value) {
    for (final kind in values) {
      if (value == kind.wireValue) return kind;
    }
    throw const FormatException('file browser node kind is invalid');
  }
}

class FileBrowserRoot {
  final String rootId;
  final String label;
  final String displayPath;

  const FileBrowserRoot({
    required this.rootId,
    required this.label,
    required this.displayPath,
  });

  factory FileBrowserRoot.fromJson(Map<String, dynamic> json) {
    _fileBrowserRequireExactKeys(json, const {
      'rootId',
      'label',
      'displayPath',
    });
    return FileBrowserRoot(
      rootId: _fileBrowserRequiredIdentifier(
        json['rootId'],
        'rootId',
        _fileBrowserMaxRootIdLength,
      ),
      label: _fileBrowserRequiredText(
        json['label'],
        'label',
        _fileBrowserMaxNameLength,
      ),
      displayPath: _fileBrowserRequiredText(
        json['displayPath'],
        'displayPath',
        _fileBrowserMaxPathLength,
      ),
    );
  }
}

class FileBrowserNode {
  final String name;
  final String relativePath;
  final FileBrowserNodeKind kind;
  final FileBrowserNodeKind? targetKind;
  final bool isSymlink;
  final int? sizeBytes;
  final String? modifiedAt;
  final String? mimeType;
  final String? previewKind;
  final bool canOpen;
  final bool canPreview;
  final bool canDownload;
  final String nodeRevision;

  const FileBrowserNode({
    required this.name,
    required this.relativePath,
    required this.kind,
    required this.targetKind,
    required this.isSymlink,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.mimeType,
    required this.previewKind,
    required this.canOpen,
    required this.canPreview,
    required this.canDownload,
    required this.nodeRevision,
  });

  factory FileBrowserNode.fromJson(Map<String, dynamic> json) {
    _fileBrowserRequireExactKeys(json, const {
      'name',
      'relativePath',
      'kind',
      'targetKind',
      'isSymlink',
      'sizeBytes',
      'modifiedAt',
      'mimeType',
      'previewKind',
      'canOpen',
      'canPreview',
      'canDownload',
      'nodeRevision',
    });
    final kind = FileBrowserNodeKind.parse(json['kind']);
    final targetKind = json.containsKey('targetKind')
        ? FileBrowserNodeKind.parse(json['targetKind'])
        : null;
    final isSymlink = _fileBrowserRequiredBool(json['isSymlink'], 'isSymlink');
    if (isSymlink != (kind == FileBrowserNodeKind.symlink) ||
        (targetKind != null && kind != FileBrowserNodeKind.symlink) ||
        targetKind == FileBrowserNodeKind.symlink) {
      throw const FormatException(
        'file browser symlink metadata is inconsistent',
      );
    }
    return FileBrowserNode(
      name: _fileBrowserRequiredName(json['name'], 'name'),
      relativePath: _fileBrowserRequiredRelativePath(
        json['relativePath'],
        allowRoot: true,
      ),
      kind: kind,
      targetKind: targetKind,
      isSymlink: isSymlink,
      sizeBytes: _fileBrowserOptionalSafeInteger(json, 'sizeBytes'),
      modifiedAt: _fileBrowserOptionalUtcTimestamp(json, 'modifiedAt'),
      mimeType: _fileBrowserOptionalText(
        json,
        'mimeType',
        _fileBrowserMaxMimeTypeLength,
      ),
      previewKind: _fileBrowserOptionalIdentifier(
        json,
        'previewKind',
        _fileBrowserMaxKindLength,
      ),
      canOpen: _fileBrowserRequiredBool(json['canOpen'], 'canOpen'),
      canPreview: _fileBrowserRequiredBool(json['canPreview'], 'canPreview'),
      canDownload: _fileBrowserRequiredBool(json['canDownload'], 'canDownload'),
      nodeRevision: _fileBrowserRequiredIdentifier(
        json['nodeRevision'],
        'nodeRevision',
        _fileBrowserMaxRevisionLength,
      ),
    );
  }
}

class FileBrowserPathRef {
  final String rootId;
  final String relativePath;

  const FileBrowserPathRef({required this.rootId, required this.relativePath});

  Map<String, dynamic> _toWireJson() => <String, dynamic>{
    'rootId': _fileBrowserOutboundIdentifier(
      rootId,
      'rootId',
      _fileBrowserMaxRootIdLength,
    ),
    'relativePath': _fileBrowserOutboundRelativePath(
      relativePath,
      allowRoot: true,
    ),
  };
}

class FileMutationOperation {
  final String transferId;
  final String filename;
  final int sizeBytes;

  const FileMutationOperation.upload({
    required this.transferId,
    required this.filename,
    required this.sizeBytes,
  });

  Map<String, dynamic> toJson() {
    if (sizeBytes < 0 || sizeBytes > maxFileBrowserDownloadBytes) {
      throw ArgumentError.value(
        sizeBytes,
        'sizeBytes',
        'must fit the file-transfer limit',
      );
    }
    return <String, dynamic>{
      'kind': 'upload',
      'transferId': _fileBrowserOutboundTransferId(transferId),
      'filename': _fileMutationOutboundFilename(filename),
      'sizeBytes': sizeBytes,
    };
  }
}

sealed class FileMutationAuthorization {
  const FileMutationAuthorization();

  Map<String, dynamic> toJson();
}

final class FileMutationPasswordAuthorization
    extends FileMutationAuthorization {
  final String password;

  const FileMutationPasswordAuthorization(this.password);

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': 'password',
    'password': _fileMutationOutboundPassword(password),
  };
}

final class FileMutationBiometricAuthorization
    extends FileMutationAuthorization {
  final String challengeId;
  final String deviceId;
  final String signature;

  const FileMutationBiometricAuthorization({
    required this.challengeId,
    required this.deviceId,
    required this.signature,
  });

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': 'biometric',
    'challengeId': _fileBrowserOutboundIdentifier(
      challengeId,
      'challengeId',
      _fileMutationMaxChallengeIdLength,
    ),
    'deviceId': _fileBrowserOutboundIdentifier(
      deviceId,
      'deviceId',
      _fileMutationMaxDeviceIdLength,
    ),
    'signature': _fileBrowserOutboundIdentifier(
      signature,
      'signature',
      _fileMutationMaxSignatureLength,
    ),
  };
}

abstract class FileBrowserResultMessage
    implements LocalFeatureTransientMessage {
  final String requestId;
  final bool success;
  final String? errorCode;
  final String? error;

  const FileBrowserResultMessage({
    required this.requestId,
    required this.success,
    this.errorCode,
    this.error,
  });

  @override
  String get featureId => fileBrowserFeatureId;

  @override
  String get sessionId => fileBrowserOwnerSessionId;
}

class FileBrowserRootsResultMessage extends FileBrowserResultMessage {
  final String? bridgeInstanceId;
  final String? rootSetRevision;
  final List<FileBrowserRoot> roots;
  final int? previewMaxBytes;
  final int? downloadMaxBytes;
  final bool? downloadAvailable;

  const FileBrowserRootsResultMessage({
    required super.requestId,
    required super.success,
    super.errorCode,
    super.error,
    this.bridgeInstanceId,
    this.rootSetRevision,
    this.roots = const [],
    this.previewMaxBytes,
    this.downloadMaxBytes,
    this.downloadAvailable,
  });

  factory FileBrowserRootsResultMessage.fromJson(Map<String, dynamic> json) {
    const payloadKeys = <String>{
      'bridgeInstanceId',
      'rootSetRevision',
      'roots',
      'previewMaxBytes',
      'downloadMaxBytes',
      'downloadAvailable',
    };
    final envelope = _fileBrowserResultEnvelope(
      json,
      expectedType: 'file_browser_roots_result_v1',
      payloadKeys: payloadKeys,
    );
    if (!envelope.success) {
      return FileBrowserRootsResultMessage(
        requestId: envelope.requestId,
        success: false,
        errorCode: envelope.errorCode,
        error: envelope.error,
      );
    }
    final rawRoots = json['roots'];
    if (rawRoots is! List || rawRoots.length > maxFileBrowserRoots) {
      throw const FormatException('file browser roots are invalid');
    }
    final roots = rawRoots
        .map((root) {
          if (root is! Map) {
            throw const FormatException('file browser root must be an object');
          }
          return FileBrowserRoot.fromJson(Map<String, dynamic>.from(root));
        })
        .toList(growable: false);
    if (roots.map((root) => root.rootId).toSet().length != roots.length) {
      throw const FormatException('file browser root ids must be unique');
    }
    final previewMaxBytes = _fileBrowserRequiredSafeInteger(
      json['previewMaxBytes'],
      'previewMaxBytes',
      maximum: maxFileBrowserPreviewBytes,
    );
    final downloadMaxBytes = _fileBrowserRequiredSafeInteger(
      json['downloadMaxBytes'],
      'downloadMaxBytes',
      maximum: maxFileBrowserDownloadBytes,
    );
    return FileBrowserRootsResultMessage(
      requestId: envelope.requestId,
      success: true,
      bridgeInstanceId: _fileBrowserRequiredIdentifier(
        json['bridgeInstanceId'],
        'bridgeInstanceId',
        _fileBrowserMaxRevisionLength,
      ),
      rootSetRevision: _fileBrowserRequiredIdentifier(
        json['rootSetRevision'],
        'rootSetRevision',
        _fileBrowserMaxRevisionLength,
      ),
      roots: List.unmodifiable(roots),
      previewMaxBytes: previewMaxBytes,
      downloadMaxBytes: downloadMaxBytes,
      downloadAvailable: _fileBrowserRequiredBool(
        json['downloadAvailable'],
        'downloadAvailable',
      ),
    );
  }
}

class FileBrowserListResultMessage extends FileBrowserResultMessage {
  final String? rootId;
  final String? relativePath;
  final String? directoryRevision;
  final List<FileBrowserNode> entries;
  final String? nextCursor;

  const FileBrowserListResultMessage({
    required super.requestId,
    required super.success,
    super.errorCode,
    super.error,
    this.rootId,
    this.relativePath,
    this.directoryRevision,
    this.entries = const [],
    this.nextCursor,
  });

  factory FileBrowserListResultMessage.fromJson(Map<String, dynamic> json) {
    const payloadKeys = <String>{
      'rootId',
      'relativePath',
      'directoryRevision',
      'entries',
      'nextCursor',
    };
    final envelope = _fileBrowserResultEnvelope(
      json,
      expectedType: 'file_browser_list_result_v1',
      payloadKeys: payloadKeys,
    );
    if (!envelope.success) {
      return FileBrowserListResultMessage(
        requestId: envelope.requestId,
        success: false,
        errorCode: envelope.errorCode,
        error: envelope.error,
      );
    }
    final rawEntries = json['entries'];
    if (rawEntries is! List || rawEntries.length > maxFileBrowserPageSize) {
      throw const FormatException('file browser entries are invalid');
    }
    final entries = rawEntries
        .map((entry) {
          if (entry is! Map) {
            throw const FormatException('file browser entry must be an object');
          }
          final node = FileBrowserNode.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (node.relativePath.isEmpty) {
            throw const FormatException(
              'file browser list entry cannot be root',
            );
          }
          return node;
        })
        .toList(growable: false);
    if (entries.map((entry) => entry.relativePath).toSet().length !=
        entries.length) {
      throw const FormatException('file browser entry paths must be unique');
    }
    return FileBrowserListResultMessage(
      requestId: envelope.requestId,
      success: true,
      rootId: _fileBrowserRequiredIdentifier(
        json['rootId'],
        'rootId',
        _fileBrowserMaxRootIdLength,
      ),
      relativePath: _fileBrowserRequiredRelativePath(
        json['relativePath'],
        allowRoot: true,
      ),
      directoryRevision: _fileBrowserRequiredIdentifier(
        json['directoryRevision'],
        'directoryRevision',
        _fileBrowserMaxRevisionLength,
      ),
      entries: List.unmodifiable(entries),
      nextCursor: _fileBrowserOptionalIdentifier(
        json,
        'nextCursor',
        _fileBrowserMaxCursorLength,
      ),
    );
  }
}

class FileBrowserStatResultItem {
  final String rootId;
  final String relativePath;
  final bool exists;
  final FileBrowserNode? node;
  final String? errorCode;

  const FileBrowserStatResultItem({
    required this.rootId,
    required this.relativePath,
    required this.exists,
    required this.node,
    required this.errorCode,
  });

  factory FileBrowserStatResultItem.fromJson(Map<String, dynamic> json) {
    _fileBrowserRequireExactKeys(json, const {
      'rootId',
      'relativePath',
      'exists',
      'node',
      'errorCode',
    });
    final rootId = _fileBrowserRequiredIdentifier(
      json['rootId'],
      'rootId',
      _fileBrowserMaxRootIdLength,
    );
    final relativePath = _fileBrowserRequiredRelativePath(
      json['relativePath'],
      allowRoot: true,
    );
    final exists = _fileBrowserRequiredBool(json['exists'], 'exists');
    final errorCode = _fileBrowserOptionalIdentifier(
      json,
      'errorCode',
      _fileBrowserMaxErrorCodeLength,
    );
    FileBrowserNode? node;
    if (exists) {
      if (!json.containsKey('node') || errorCode != null) {
        throw const FormatException(
          'existing file browser stat item requires only a node',
        );
      }
      final rawNode = json['node'];
      if (rawNode is! Map) {
        throw const FormatException('file browser stat node is invalid');
      }
      node = FileBrowserNode.fromJson(Map<String, dynamic>.from(rawNode));
      if (node.relativePath != relativePath) {
        throw const FormatException('file browser stat node path mismatch');
      }
    } else if (json.containsKey('node')) {
      throw const FormatException(
        'missing file browser stat item cannot contain a node',
      );
    }
    return FileBrowserStatResultItem(
      rootId: rootId,
      relativePath: relativePath,
      exists: exists,
      node: node,
      errorCode: errorCode,
    );
  }
}

class FileBrowserStatResultMessage extends FileBrowserResultMessage {
  final List<FileBrowserStatResultItem> items;

  const FileBrowserStatResultMessage({
    required super.requestId,
    required super.success,
    super.errorCode,
    super.error,
    this.items = const [],
  });

  factory FileBrowserStatResultMessage.fromJson(Map<String, dynamic> json) {
    const payloadKeys = <String>{'items'};
    final envelope = _fileBrowserResultEnvelope(
      json,
      expectedType: 'file_browser_stat_result_v1',
      payloadKeys: payloadKeys,
    );
    if (!envelope.success) {
      return FileBrowserStatResultMessage(
        requestId: envelope.requestId,
        success: false,
        errorCode: envelope.errorCode,
        error: envelope.error,
      );
    }
    final rawItems = json['items'];
    if (rawItems is! List ||
        rawItems.isEmpty ||
        rawItems.length > maxFileBrowserStatItems) {
      throw const FormatException('file browser stat items are invalid');
    }
    final items = rawItems
        .map((item) {
          if (item is! Map) {
            throw const FormatException(
              'file browser stat item must be an object',
            );
          }
          return FileBrowserStatResultItem.fromJson(
            Map<String, dynamic>.from(item),
          );
        })
        .toList(growable: false);
    final keys = items
        .map((item) => '${item.rootId}\u0000${item.relativePath}')
        .toSet();
    if (keys.length != items.length) {
      throw const FormatException('file browser stat items must be unique');
    }
    return FileBrowserStatResultMessage(
      requestId: envelope.requestId,
      success: true,
      items: List.unmodifiable(items),
    );
  }
}

class FileBrowserPreviewResultMessage extends FileBrowserResultMessage {
  final String? rootId;
  final String? relativePath;
  final String? relativeUrl;
  final String? filename;
  final String? mimeType;
  final int? sizeBytes;
  final String? previewKind;
  final String? expiresAt;

  const FileBrowserPreviewResultMessage({
    required super.requestId,
    required super.success,
    super.errorCode,
    super.error,
    this.rootId,
    this.relativePath,
    this.relativeUrl,
    this.filename,
    this.mimeType,
    this.sizeBytes,
    this.previewKind,
    this.expiresAt,
  });

  factory FileBrowserPreviewResultMessage.fromJson(Map<String, dynamic> json) {
    const payloadKeys = <String>{
      'rootId',
      'relativePath',
      'relativeUrl',
      'filename',
      'mimeType',
      'sizeBytes',
      'previewKind',
      'expiresAt',
    };
    final envelope = _fileBrowserResultEnvelope(
      json,
      expectedType: 'file_browser_preview_result_v1',
      payloadKeys: payloadKeys,
    );
    if (!envelope.success) {
      return FileBrowserPreviewResultMessage(
        requestId: envelope.requestId,
        success: false,
        errorCode: envelope.errorCode,
        error: envelope.error,
      );
    }
    return FileBrowserPreviewResultMessage(
      requestId: envelope.requestId,
      success: true,
      rootId: _fileBrowserRequiredIdentifier(
        json['rootId'],
        'rootId',
        _fileBrowserMaxRootIdLength,
      ),
      relativePath: _fileBrowserRequiredRelativePath(
        json['relativePath'],
        allowRoot: false,
      ),
      relativeUrl: _fileBrowserRequiredRelativeUrl(json['relativeUrl']),
      filename: _fileBrowserRequiredName(json['filename'], 'filename'),
      mimeType: _fileBrowserRequiredText(
        json['mimeType'],
        'mimeType',
        _fileBrowserMaxMimeTypeLength,
      ),
      sizeBytes: _fileBrowserRequiredSafeInteger(
        json['sizeBytes'],
        'sizeBytes',
        maximum: maxFileBrowserPreviewBytes,
      ),
      previewKind: _fileBrowserRequiredIdentifier(
        json['previewKind'],
        'previewKind',
        _fileBrowserMaxKindLength,
      ),
      expiresAt: _fileBrowserRequiredUtcTimestamp(
        json['expiresAt'],
        'expiresAt',
      ),
    );
  }
}

class FileBrowserDownloadResultMessage extends FileBrowserResultMessage {
  final String? rootId;
  final String? relativePath;
  final String? transferId;
  final String? status;

  const FileBrowserDownloadResultMessage({
    required super.requestId,
    required super.success,
    super.errorCode,
    super.error,
    this.rootId,
    this.relativePath,
    this.transferId,
    this.status,
  });

  factory FileBrowserDownloadResultMessage.fromJson(Map<String, dynamic> json) {
    const payloadKeys = <String>{
      'rootId',
      'relativePath',
      'transferId',
      'status',
    };
    final envelope = _fileBrowserResultEnvelope(
      json,
      expectedType: 'file_browser_download_result_v1',
      payloadKeys: payloadKeys,
    );
    if (!envelope.success) {
      return FileBrowserDownloadResultMessage(
        requestId: envelope.requestId,
        success: false,
        errorCode: envelope.errorCode,
        error: envelope.error,
      );
    }
    final status = _fileBrowserRequiredIdentifier(
      json['status'],
      'status',
      _fileBrowserMaxKindLength,
    );
    if (status != 'queued') {
      throw const FormatException('file browser download status is invalid');
    }
    return FileBrowserDownloadResultMessage(
      requestId: envelope.requestId,
      success: true,
      rootId: _fileBrowserRequiredIdentifier(
        json['rootId'],
        'rootId',
        _fileBrowserMaxRootIdLength,
      ),
      relativePath: _fileBrowserRequiredRelativePath(
        json['relativePath'],
        allowRoot: false,
      ),
      transferId: _fileBrowserRequiredTransferId(json['transferId']),
      status: status,
    );
  }
}

enum FileMutationAuthEvent {
  state('state'),
  enrolled('enrolled'),
  challenge('challenge');

  const FileMutationAuthEvent(this.wireValue);

  final String wireValue;

  static FileMutationAuthEvent parse(Object? value) {
    for (final event in values) {
      if (event.wireValue == value) return event;
    }
    throw const FormatException('file mutation auth event is invalid');
  }
}

class FileMutationAuthResultMessage extends FileBrowserResultMessage {
  final FileMutationAuthEvent? event;
  final bool? passwordConfigured;
  final bool? biometricEnrolled;
  final String? challengeId;
  final String? payload;
  final String? expiresAt;

  const FileMutationAuthResultMessage({
    required super.requestId,
    required super.success,
    super.errorCode,
    super.error,
    this.event,
    this.passwordConfigured,
    this.biometricEnrolled,
    this.challengeId,
    this.payload,
    this.expiresAt,
  });

  factory FileMutationAuthResultMessage.fromJson(Map<String, dynamic> json) {
    const payloadKeys = <String>{
      'event',
      'passwordConfigured',
      'biometricEnrolled',
      'challengeId',
      'payload',
      'expiresAt',
    };
    final envelope = _fileBrowserResultEnvelope(
      json,
      expectedType: 'file_mutation_auth_result_v1',
      payloadKeys: payloadKeys,
    );
    if (!envelope.success) {
      return FileMutationAuthResultMessage(
        requestId: envelope.requestId,
        success: false,
        errorCode: envelope.errorCode,
        error: envelope.error,
      );
    }
    final event = FileMutationAuthEvent.parse(json['event']);
    switch (event) {
      case FileMutationAuthEvent.state:
      case FileMutationAuthEvent.enrolled:
        if (json.containsKey('challengeId') ||
            json.containsKey('payload') ||
            json.containsKey('expiresAt')) {
          throw const FormatException(
            'file mutation auth state contains challenge fields',
          );
        }
        return FileMutationAuthResultMessage(
          requestId: envelope.requestId,
          success: true,
          event: event,
          passwordConfigured: _fileBrowserRequiredBool(
            json['passwordConfigured'],
            'passwordConfigured',
          ),
          biometricEnrolled: _fileBrowserRequiredBool(
            json['biometricEnrolled'],
            'biometricEnrolled',
          ),
        );
      case FileMutationAuthEvent.challenge:
        if (json.containsKey('passwordConfigured') ||
            json.containsKey('biometricEnrolled')) {
          throw const FormatException(
            'file mutation auth challenge contains state fields',
          );
        }
        return FileMutationAuthResultMessage(
          requestId: envelope.requestId,
          success: true,
          event: event,
          challengeId: _fileBrowserRequiredIdentifier(
            json['challengeId'],
            'challengeId',
            _fileMutationMaxChallengeIdLength,
          ),
          payload: _fileBrowserRequiredText(
            json['payload'],
            'payload',
            _fileMutationMaxChallengePayloadLength,
          ),
          expiresAt: _fileBrowserRequiredUtcTimestamp(
            json['expiresAt'],
            'expiresAt',
          ),
        );
    }
  }
}

ClientMessage requestFileBrowserRoots({required String requestId}) =>
    _fileBrowserRequest(type: 'file_browser_roots_v1', requestId: requestId);

ClientMessage requestFileBrowserList({
  required String requestId,
  required String rootId,
  String relativePath = '',
  String? cursor,
  int? pageSize,
  bool? showHidden,
}) {
  if (pageSize != null && (pageSize < 1 || pageSize > maxFileBrowserPageSize)) {
    throw ArgumentError.value(pageSize, 'pageSize', 'must be from 1 to 200');
  }
  return _fileBrowserRequest(
    type: 'file_browser_list_v1',
    requestId: requestId,
    fields: <String, dynamic>{
      'rootId': _fileBrowserOutboundIdentifier(
        rootId,
        'rootId',
        _fileBrowserMaxRootIdLength,
      ),
      'relativePath': _fileBrowserOutboundRelativePath(
        relativePath,
        allowRoot: true,
      ),
      if (cursor != null)
        'cursor': _fileBrowserOutboundIdentifier(
          cursor,
          'cursor',
          _fileBrowserMaxCursorLength,
        ),
      'pageSize': ?pageSize,
      'showHidden': ?showHidden,
    },
  );
}

ClientMessage requestFileBrowserStat({
  required String requestId,
  required List<FileBrowserPathRef> items,
}) {
  if (items.isEmpty || items.length > maxFileBrowserStatItems) {
    throw ArgumentError.value(
      items.length,
      'items',
      'must contain from 1 to 32 paths',
    );
  }
  final wireItems = items.map((item) => item._toWireJson()).toList();
  final keys = wireItems
      .map((item) => '${item['rootId']}\u0000${item['relativePath']}')
      .toSet();
  if (keys.length != wireItems.length) {
    throw ArgumentError.value(items, 'items', 'must not contain duplicates');
  }
  return _fileBrowserRequest(
    type: 'file_browser_stat_v1',
    requestId: requestId,
    fields: <String, dynamic>{'items': wireItems},
  );
}

ClientMessage requestFileBrowserPreview({
  required String requestId,
  required String rootId,
  required String relativePath,
  String? nodeRevision,
}) => _fileBrowserNodeActionRequest(
  type: 'file_browser_preview_v1',
  requestId: requestId,
  rootId: rootId,
  relativePath: relativePath,
  nodeRevision: nodeRevision,
);

ClientMessage requestFileBrowserDownload({
  required String requestId,
  required String rootId,
  required String relativePath,
  String? nodeRevision,
}) => _fileBrowserNodeActionRequest(
  type: 'file_browser_download_v1',
  requestId: requestId,
  rootId: rootId,
  relativePath: relativePath,
  nodeRevision: nodeRevision,
);

ClientMessage requestFileMutationAuthState({
  required String requestId,
  String? deviceId,
}) => _fileBrowserRequest(
  type: 'file_mutation_auth_state_v1',
  requestId: requestId,
  fields: <String, dynamic>{
    if (deviceId != null)
      'deviceId': _fileBrowserOutboundIdentifier(
        deviceId,
        'deviceId',
        _fileMutationMaxDeviceIdLength,
      ),
  },
);

ClientMessage requestFileMutationAuthChallenge({
  required String requestId,
  required String deviceId,
  required FileMutationOperation operation,
}) => _fileBrowserRequest(
  type: 'file_mutation_auth_challenge_v1',
  requestId: requestId,
  fields: <String, dynamic>{
    'deviceId': _fileBrowserOutboundIdentifier(
      deviceId,
      'deviceId',
      _fileMutationMaxDeviceIdLength,
    ),
    'operation': operation.toJson(),
  },
);

ClientMessage requestFileMutationAuthEnroll({
  required String requestId,
  required String deviceId,
  required String publicKey,
  required String password,
}) => _fileBrowserRequest(
  type: 'file_mutation_auth_enroll_v1',
  requestId: requestId,
  fields: <String, dynamic>{
    'deviceId': _fileBrowserOutboundIdentifier(
      deviceId,
      'deviceId',
      _fileMutationMaxDeviceIdLength,
    ),
    'publicKey': _fileBrowserOutboundIdentifier(
      publicKey,
      'publicKey',
      _fileMutationMaxPublicKeyLength,
    ),
    'password': _fileMutationOutboundPassword(password),
  },
);

ClientMessage _fileBrowserNodeActionRequest({
  required String type,
  required String requestId,
  required String rootId,
  required String relativePath,
  String? nodeRevision,
}) => _fileBrowserRequest(
  type: type,
  requestId: requestId,
  fields: <String, dynamic>{
    'rootId': _fileBrowserOutboundIdentifier(
      rootId,
      'rootId',
      _fileBrowserMaxRootIdLength,
    ),
    'relativePath': _fileBrowserOutboundRelativePath(
      relativePath,
      allowRoot: false,
    ),
    if (nodeRevision != null)
      'nodeRevision': _fileBrowserOutboundIdentifier(
        nodeRevision,
        'nodeRevision',
        _fileBrowserMaxRevisionLength,
      ),
  },
);

ClientMessage _fileBrowserRequest({
  required String type,
  required String requestId,
  Map<String, dynamic> fields = const {},
}) {
  if (!_FileBrowserProtocolSlot.requestTypes.contains(type)) {
    throw ArgumentError.value(type, 'type', 'is not a file browser request');
  }
  return ClientMessage._(<String, dynamic>{
    'type': type,
    'requestId': _fileBrowserOutboundIdentifier(
      requestId,
      'requestId',
      _fileBrowserMaxRequestIdLength,
    ),
    ...fields,
  }, delivery: ClientMessageDelivery.ephemeral);
}

class _FileBrowserResultEnvelope {
  final String requestId;
  final bool success;
  final String? errorCode;
  final String? error;

  const _FileBrowserResultEnvelope({
    required this.requestId,
    required this.success,
    this.errorCode,
    this.error,
  });
}

_FileBrowserResultEnvelope _fileBrowserResultEnvelope(
  Map<String, dynamic> json, {
  required String expectedType,
  required Set<String> payloadKeys,
}) {
  _fileBrowserRequireExactKeys(json, <String>{
    'type',
    'requestId',
    'success',
    'errorCode',
    'error',
    ...payloadKeys,
  });
  if (json['type'] != expectedType) {
    throw FormatException('expected file browser result $expectedType');
  }
  final requestId = _fileBrowserRequiredIdentifier(
    json['requestId'],
    'requestId',
    _fileBrowserMaxRequestIdLength,
  );
  final success = _fileBrowserRequiredBool(json['success'], 'success');
  if (success) {
    if (json.containsKey('errorCode') || json.containsKey('error')) {
      throw const FormatException(
        'successful file browser result cannot contain an error',
      );
    }
    return _FileBrowserResultEnvelope(requestId: requestId, success: true);
  }
  for (final key in payloadKeys) {
    if (json.containsKey(key)) {
      throw FormatException(
        'failed file browser result cannot contain payload field $key',
      );
    }
  }
  return _FileBrowserResultEnvelope(
    requestId: requestId,
    success: false,
    errorCode: _fileBrowserOptionalIdentifier(
      json,
      'errorCode',
      _fileBrowserMaxErrorCodeLength,
    ),
    error: _fileBrowserOptionalText(json, 'error', _fileBrowserMaxErrorLength),
  );
}

void _fileBrowserRequireExactKeys(
  Map<String, dynamic> json,
  Set<String> allowed,
) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('file browser message has unknown field $key');
    }
  }
}

String _fileBrowserRequiredText(Object? value, String field, int maxLength) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maxLength ||
      value.contains('\u0000')) {
    throw FormatException('file browser $field is invalid');
  }
  return value;
}

String? _fileBrowserOptionalText(
  Map<String, dynamic> json,
  String field,
  int maxLength,
) {
  if (!json.containsKey(field)) return null;
  return _fileBrowserRequiredText(json[field], field, maxLength);
}

bool _fileBrowserIsBoundedIdentifier(Object? value, int maxLength) =>
    value is String &&
    value.isNotEmpty &&
    value.trim() == value &&
    value.length <= maxLength &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

String _fileBrowserRequiredIdentifier(
  Object? value,
  String field,
  int maxLength,
) {
  if (!_fileBrowserIsBoundedIdentifier(value, maxLength)) {
    throw FormatException('file browser $field is invalid');
  }
  return value as String;
}

String? _fileBrowserOptionalIdentifier(
  Map<String, dynamic> json,
  String field,
  int maxLength,
) {
  if (!json.containsKey(field)) return null;
  return _fileBrowserRequiredIdentifier(json[field], field, maxLength);
}

String _fileBrowserOutboundIdentifier(
  String value,
  String field,
  int maxLength,
) {
  if (!_fileBrowserIsBoundedIdentifier(value, maxLength)) {
    throw ArgumentError.value(value, field, 'must be non-empty and bounded');
  }
  return value;
}

bool _fileBrowserRequiredBool(Object? value, String field) {
  if (value is! bool) {
    throw FormatException('file browser $field must be a bool');
  }
  return value;
}

String _fileBrowserRequiredName(Object? value, String field) {
  final name = _fileBrowserRequiredText(
    value,
    field,
    _fileBrowserMaxNameLength,
  );
  if (name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\\') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
    throw FormatException('file browser $field is invalid');
  }
  return name;
}

String _fileBrowserRequiredRelativePath(
  Object? value, {
  required bool allowRoot,
}) {
  if (value is! String ||
      value.length > _fileBrowserMaxPathLength ||
      value.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      value.contains('\\') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException('file browser relativePath is invalid');
  }
  if (value.isEmpty) {
    if (allowRoot) return value;
    throw const FormatException('file browser relativePath cannot be root');
  }
  final segments = value.split('/');
  if (segments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.length > _fileBrowserMaxNameLength,
  )) {
    throw const FormatException('file browser relativePath is invalid');
  }
  return value;
}

String _fileBrowserOutboundRelativePath(
  String value, {
  required bool allowRoot,
}) {
  try {
    return _fileBrowserRequiredRelativePath(value, allowRoot: allowRoot);
  } on FormatException {
    throw ArgumentError.value(value, 'relativePath', 'is invalid');
  }
}

int _fileBrowserRequiredSafeInteger(
  Object? value,
  String field, {
  int maximum = _fileBrowserMaxSafeInteger,
}) {
  if (value is! int || value < 0 || value > maximum) {
    throw FormatException('file browser $field is invalid');
  }
  return value;
}

int? _fileBrowserOptionalSafeInteger(Map<String, dynamic> json, String field) {
  if (!json.containsKey(field)) return null;
  return _fileBrowserRequiredSafeInteger(json[field], field);
}

String _fileBrowserRequiredUtcTimestamp(Object? value, String field) {
  final text = _fileBrowserRequiredText(value, field, 32);
  final parsed = DateTime.tryParse(text);
  if (!text.endsWith('Z') || parsed == null || !parsed.isUtc) {
    throw FormatException('file browser $field must be a UTC ISO-8601 value');
  }
  return text;
}

String? _fileBrowserOptionalUtcTimestamp(
  Map<String, dynamic> json,
  String field,
) {
  if (!json.containsKey(field)) return null;
  return _fileBrowserRequiredUtcTimestamp(json[field], field);
}

String _fileBrowserRequiredRelativeUrl(Object? value) {
  final text = _fileBrowserRequiredText(
    value,
    'relativeUrl',
    _fileBrowserMaxRelativeUrlLength,
  );
  Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    throw const FormatException('file browser relativeUrl is invalid');
  }
  if (!text.startsWith('/') ||
      text.startsWith('//') ||
      text.contains('\\') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(text) ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.fragment.isNotEmpty) {
    throw const FormatException(
      'file browser relativeUrl must remain same-origin',
    );
  }
  return text;
}

String _fileBrowserRequiredTransferId(Object? value) {
  final text = _fileBrowserRequiredIdentifier(value, 'transferId', 128);
  if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(text)) {
    throw const FormatException('file browser transferId is invalid');
  }
  return text;
}

String _fileBrowserOutboundTransferId(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'transferId', 'is invalid');
  }
  return value;
}

String _fileMutationOutboundFilename(String value) {
  if (value.trim().isEmpty ||
      value.length > _fileMutationMaxFilenameLength ||
      value.contains('\u0000')) {
    throw ArgumentError.value(value, 'filename', 'is invalid');
  }
  return value;
}

String _fileMutationOutboundPassword(String value) {
  if (value.length < 8 ||
      value.length > _fileMutationMaxPasswordLength ||
      value.contains('\u0000')) {
    throw ArgumentError.value(value, 'password', 'must contain 8–256 chars');
  }
  return value;
}
