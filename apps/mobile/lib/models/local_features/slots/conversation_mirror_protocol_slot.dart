part of '../../messages.dart';

const LocalFeatureProtocolSlot conversationMirrorProtocolSlot =
    _ConversationMirrorProtocolSlot();
const conversationMirrorSourceIdentityCapability =
    'conversation_mirror_source_identity_v1';

// Mirror snapshot pages are bounded by the local store's 100-entry page
// limit. Patches do not carry a page count, but their inline lists still need
// a finite safety bound before per-entry wrappers are materialized.
const _conversationMirrorMaxInlineEntries = 2000;
const _conversationMirrorMaxSnapshotPageEntries = 100;
const _conversationMirrorMaxInlineDeletes = 2000;
const _conversationMirrorMaxEntryBytes = 512 * 1024;
const _conversationMirrorMaxEntryIdLength = 512;
const _conversationMirrorMaxContentHashLength = 128;

class _ConversationMirrorProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _ConversationMirrorProtocolSlot();

  @override
  String get featureId => 'conversation_mirror';

  @override
  List<String> get supportedServerMessageTypes => const [
    'conversation_mirror_event_v1',
    'conversation_mirror_entry_chunk_v1',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) {
    return switch (json['type']) {
      'conversation_mirror_event_v1' =>
        ConversationMirrorEventMessage.fromJson(json),
      'conversation_mirror_entry_chunk_v1' =>
        ConversationMirrorEntryChunkMessage.fromJson(json),
      _ => null,
    };
  }

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (!const {
      'conversation_mirror_probe',
      'conversation_mirror_sync',
      'conversation_mirror_watch',
      'conversation_mirror_unwatch',
    }.contains(type)) {
      return null;
    }
    final providerSessionId = request['providerSessionId'];
    final requestId = request['requestId'];
    if (providerSessionId is! String || requestId is! String) return null;
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: type as String,
      ownerSessionId: providerSessionId,
      requestId: requestId,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) {
    if (response is! ConversationMirrorEventMessage ||
        response.providerSessionId != request.ownerSessionId ||
        response.requestId != request.requestId) {
      return false;
    }
    if (response.event == ConversationMirrorEventKind.error) return true;
    return switch (request.requestType) {
      'conversation_mirror_probe' =>
        response.event == ConversationMirrorEventKind.probe,
      'conversation_mirror_sync' =>
        response.event == ConversationMirrorEventKind.snapshotComplete ||
            response.event == ConversationMirrorEventKind.notModified,
      'conversation_mirror_watch' =>
        response.event == ConversationMirrorEventKind.watching ||
            response.event == ConversationMirrorEventKind.notModified,
      'conversation_mirror_unwatch' =>
        response.event == ConversationMirrorEventKind.unwatched,
      _ => false,
    };
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) {
    if (error.errorCode == 'unsupported_capability' &&
        error.message == 'Conversation mirror capability was not negotiated') {
      return true;
    }
    // Bridges predating `unsupported_message` sometimes returned a generic
    // error. Correlate it only when the exact request type is named, so an
    // unrelated session error can never consume this feature's pending slot.
    final message = error.message.toLowerCase();
    return message.contains(request.requestType.toLowerCase()) &&
        RegExp(
          r'\b(unknown|unsupported|unrecognized)\b|not supported|invalid message type',
        ).hasMatch(message);
  }
}

enum ConversationMirrorEventKind {
  accepted('accepted'),
  probe('probe'),
  snapshotBegin('snapshot_begin'),
  snapshotPage('snapshot_page'),
  snapshotComplete('snapshot_complete'),
  watching('watching'),
  patch('patch'),
  notModified('not_modified'),
  unwatched('unwatched'),
  error('error'),
  unknown('__unknown__');

  final String wireValue;
  const ConversationMirrorEventKind(this.wireValue);

  static ConversationMirrorEventKind parse(Object? value) {
    for (final event in values) {
      if (event.wireValue == value) return event;
    }
    return unknown;
  }
}

class ConversationMirrorWireEntry {
  final String entryId;
  final int index;
  final String contentHash;
  final Map<String, dynamic> rawMessage;

  const ConversationMirrorWireEntry({
    required this.entryId,
    required this.index,
    required this.contentHash,
    required this.rawMessage,
  });

  ServerMessage decodeMessage() => ServerMessage.fromJson(rawMessage);

  factory ConversationMirrorWireEntry.fromJson(Map<String, dynamic> json) {
    final rawMessage = json['message'];
    if (rawMessage is! Map) {
      throw const FormatException('Conversation mirror message must be a map.');
    }
    final normalized = Map<String, dynamic>.from(rawMessage);
    return ConversationMirrorWireEntry(
      entryId: _conversationMirrorRequiredString(
        json,
        'entryId',
        maximumLength: _conversationMirrorMaxEntryIdLength,
      ),
      index: _conversationMirrorRequiredInt(json, 'index', minimum: 0),
      contentHash: _conversationMirrorRequiredString(
        json,
        'contentHash',
        maximumLength: _conversationMirrorMaxContentHashLength,
      ),
      rawMessage: Map.unmodifiable(normalized),
    );
  }
}

class ConversationMirrorEntryChunkMessage
    implements LocalFeatureTransientMessage {
  @override
  String get featureId => 'conversation_mirror';

  final String requestId;
  final String bridgeInstanceId;
  final String provider;
  final String providerSessionId;
  final String revision;
  final int pageIndex;
  final int pageCount;
  final String entryId;
  final int index;
  final String contentHash;
  final int chunkIndex;
  final int chunkCount;
  final int totalBytes;
  final String payloadBase64;

  const ConversationMirrorEntryChunkMessage({
    required this.requestId,
    required this.bridgeInstanceId,
    required this.provider,
    required this.providerSessionId,
    required this.revision,
    required this.pageIndex,
    required this.pageCount,
    required this.entryId,
    required this.index,
    required this.contentHash,
    required this.chunkIndex,
    required this.chunkCount,
    required this.totalBytes,
    required this.payloadBase64,
  });

  @override
  String get sessionId => providerSessionId;

  factory ConversationMirrorEntryChunkMessage.fromJson(
    Map<String, dynamic> json,
  ) {
    final provider = _conversationMirrorRequiredString(json, 'provider');
    if (!const {'codex', 'claude'}.contains(provider)) {
      throw FormatException(
        'Unsupported conversation mirror provider: $provider',
      );
    }
    final pageIndex = _conversationMirrorRequiredInt(
      json,
      'pageIndex',
      minimum: 0,
    );
    final pageCount = _conversationMirrorRequiredInt(
      json,
      'pageCount',
      minimum: 1,
    );
    final chunkIndex = _conversationMirrorRequiredInt(
      json,
      'chunkIndex',
      minimum: 0,
    );
    final chunkCount = _conversationMirrorRequiredInt(
      json,
      'chunkCount',
      minimum: 1,
    );
    final totalBytes = _conversationMirrorRequiredInt(
      json,
      'totalBytes',
      minimum: 1,
    );
    final contentHash = _conversationMirrorRequiredString(
      json,
      'contentHash',
    );
    final payloadBase64 = _conversationMirrorRequiredString(
      json,
      'payloadBase64',
    );
    if (pageIndex >= pageCount ||
        chunkIndex >= chunkCount ||
        chunkCount > 256 ||
        totalBytes > 64 * 1024 * 1024 ||
        payloadBase64.length > 400000 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(contentHash)) {
      throw const FormatException('Invalid conversation mirror entry chunk.');
    }
    return ConversationMirrorEntryChunkMessage(
      requestId: _conversationMirrorRequiredString(json, 'requestId'),
      bridgeInstanceId: _conversationMirrorRequiredString(
        json,
        'bridgeInstanceId',
      ),
      provider: provider,
      providerSessionId: _conversationMirrorRequiredString(
        json,
        'providerSessionId',
      ),
      revision: _conversationMirrorRequiredString(json, 'revision'),
      pageIndex: pageIndex,
      pageCount: pageCount,
      entryId: _conversationMirrorRequiredString(json, 'entryId'),
      index: _conversationMirrorRequiredInt(json, 'index', minimum: 0),
      contentHash: contentHash,
      chunkIndex: chunkIndex,
      chunkCount: chunkCount,
      totalBytes: totalBytes,
      payloadBase64: payloadBase64,
    );
  }
}

class ConversationMirrorEventMessage implements LocalFeatureTransientMessage {
  @override
  String get featureId => 'conversation_mirror';

  final ConversationMirrorEventKind event;
  final String requestId;
  final String bridgeInstanceId;
  final String provider;
  final String providerSessionId;
  final String? revision;
  final String? baseRevision;
  final int? entryCount;
  final int? totalBytes;
  final int? pageIndex;
  final int? pageCount;
  final String? threadStatus;
  final bool notModified;
  final List<ConversationMirrorWireEntry> entries;
  final List<String> deletes;
  final int malformedEntryCount;
  final int malformedDeleteCount;
  final String? errorCode;
  final String? error;

  const ConversationMirrorEventMessage({
    required this.event,
    required this.requestId,
    required this.bridgeInstanceId,
    required this.provider,
    required this.providerSessionId,
    this.revision,
    this.baseRevision,
    this.entryCount,
    this.totalBytes,
    this.pageIndex,
    this.pageCount,
    this.threadStatus,
    this.notModified = false,
    this.entries = const [],
    this.deletes = const [],
    this.malformedEntryCount = 0,
    this.malformedDeleteCount = 0,
    this.errorCode,
    this.error,
  });

  @override
  String get sessionId => providerSessionId;

  factory ConversationMirrorEventMessage.fromJson(Map<String, dynamic> json) {
    final event = ConversationMirrorEventKind.parse(json['event']);
    final provider = _conversationMirrorRequiredString(json, 'provider');
    if (!const {'codex', 'claude'}.contains(provider)) {
      throw FormatException(
        'Unsupported conversation mirror provider: $provider',
      );
    }
    final rawEntries = switch (event) {
      ConversationMirrorEventKind.patch => json['upserts'],
      _ => json['entries'],
    };
    final entryResult = rawEntries == null
        ? const _ConversationMirrorListResult<ConversationMirrorWireEntry>()
        : _conversationMirrorEntryList(
            rawEntries,
            maximumLength: event == ConversationMirrorEventKind.snapshotPage
                ? _conversationMirrorMaxSnapshotPageEntries
                : _conversationMirrorMaxInlineEntries,
          );
    final deleteResult = _conversationMirrorStringList(json['deletes']);
    final message = ConversationMirrorEventMessage(
      event: event,
      requestId: _conversationMirrorRequiredString(json, 'requestId'),
      bridgeInstanceId: _conversationMirrorRequiredString(
        json,
        'bridgeInstanceId',
      ),
      provider: provider,
      providerSessionId: _conversationMirrorRequiredString(
        json,
        'providerSessionId',
      ),
      revision: _conversationMirrorOptionalString(json, 'revision'),
      baseRevision: _conversationMirrorOptionalString(json, 'baseRevision'),
      entryCount: _conversationMirrorOptionalInt(
        json,
        'entryCount',
        minimum: 0,
      ),
      totalBytes: _conversationMirrorOptionalInt(
        json,
        'totalBytes',
        minimum: 0,
      ),
      pageIndex: _conversationMirrorOptionalInt(json, 'pageIndex', minimum: 0),
      pageCount: _conversationMirrorOptionalInt(json, 'pageCount', minimum: 0),
      threadStatus: _conversationMirrorOptionalString(json, 'threadStatus'),
      // The v1 Bridge requires this only on probe responses. Missing or
      // wrongly typed values fail safe to false, so a malformed flag can
      // trigger normal reconciliation but can never claim a changed snapshot
      // is unchanged.
      notModified: _conversationMirrorOptionalBool(
        json,
        'notModified',
        fallback: false,
      ),
      entries: entryResult.values,
      deletes: deleteResult.values,
      malformedEntryCount: entryResult.malformedCount,
      malformedDeleteCount: deleteResult.malformedCount,
      errorCode: _conversationMirrorOptionalString(json, 'errorCode'),
      error: _conversationMirrorOptionalString(json, 'error'),
    );
    _validateConversationMirrorEvent(message);
    return message;
  }
}

ClientMessage requestConversationMirrorProbe({
  required String requestId,
  required String provider,
  required String providerSessionId,
  required String projectPath,
  String? knownRevision,
  String? codexSourceId,
}) => _conversationMirrorClientMessage(
  type: 'conversation_mirror_probe',
  requestId: requestId,
  provider: provider,
  providerSessionId: providerSessionId,
  projectPath: projectPath,
  knownRevision: knownRevision,
  codexSourceId: codexSourceId,
);

ClientMessage requestConversationMirrorSync({
  required String requestId,
  required String provider,
  required String providerSessionId,
  required String projectPath,
  String? knownRevision,
  String? codexSourceId,
}) => _conversationMirrorClientMessage(
  type: 'conversation_mirror_sync',
  requestId: requestId,
  provider: provider,
  providerSessionId: providerSessionId,
  projectPath: projectPath,
  knownRevision: knownRevision,
  codexSourceId: codexSourceId,
);

ClientMessage requestConversationMirrorWatch({
  required String requestId,
  required String provider,
  required String providerSessionId,
  required String projectPath,
  String? knownRevision,
  String? codexSourceId,
}) => _conversationMirrorClientMessage(
  type: 'conversation_mirror_watch',
  requestId: requestId,
  provider: provider,
  providerSessionId: providerSessionId,
  projectPath: projectPath,
  knownRevision: knownRevision,
  codexSourceId: codexSourceId,
);

ClientMessage requestConversationMirrorUnwatch({
  required String requestId,
  required String provider,
  required String providerSessionId,
  String? codexSourceId,
}) => _conversationMirrorClientMessage(
  type: 'conversation_mirror_unwatch',
  requestId: requestId,
  provider: provider,
  providerSessionId: providerSessionId,
  codexSourceId: codexSourceId,
);

ClientMessage _conversationMirrorClientMessage({
  required String type,
  required String requestId,
  required String provider,
  required String providerSessionId,
  String? projectPath,
  String? knownRevision,
  String? codexSourceId,
}) {
  if (!const {'codex', 'claude'}.contains(provider)) {
    throw ArgumentError.value(provider, 'provider', 'must be codex or claude');
  }
  if (codexSourceId != null && provider != 'codex') {
    throw ArgumentError.value(
      codexSourceId,
      'codexSourceId',
      'is only valid for Codex conversations',
    );
  }
  final fields = <String, dynamic>{
    'type': type,
    'protocolVersion': 1,
    'requestId': _conversationMirrorClientId(requestId, 'requestId', 128),
    'provider': provider,
    'providerSessionId': _conversationMirrorClientId(
      providerSessionId,
      'providerSessionId',
      256,
    ),
    if (codexSourceId != null)
      'codexSourceId': _conversationMirrorClientId(
        codexSourceId,
        'codexSourceId',
        128,
      ),
    'projectPath': ?projectPath,
    if (knownRevision != null)
      'knownRevision': _conversationMirrorClientId(
        knownRevision,
        'knownRevision',
        128,
      ),
  };
  return ClientMessage._(fields, delivery: ClientMessageDelivery.ephemeral);
}

void _validateConversationMirrorEvent(ConversationMirrorEventMessage message) {
  bool hasRevision() => message.revision != null;
  switch (message.event) {
    case ConversationMirrorEventKind.accepted:
      break;
    case ConversationMirrorEventKind.probe:
      if (!hasRevision() ||
          message.entryCount == null ||
          message.totalBytes == null) {
        throw const FormatException('Incomplete conversation mirror probe.');
      }
    case ConversationMirrorEventKind.snapshotBegin:
      if (!hasRevision() ||
          message.entryCount == null ||
          message.totalBytes == null ||
          message.pageCount == null) {
        throw const FormatException('Incomplete mirror snapshot begin.');
      }
    case ConversationMirrorEventKind.snapshotPage:
      if (!hasRevision() ||
          message.pageIndex == null ||
          message.pageCount == null) {
        throw const FormatException('Incomplete mirror snapshot page.');
      }
    case ConversationMirrorEventKind.snapshotComplete:
      if (!hasRevision() || message.entryCount == null) {
        throw const FormatException('Incomplete mirror snapshot completion.');
      }
    case ConversationMirrorEventKind.watching ||
        ConversationMirrorEventKind.notModified:
      if (!hasRevision()) {
        throw const FormatException('Mirror watch response has no revision.');
      }
    case ConversationMirrorEventKind.patch:
      if (!hasRevision() || message.baseRevision == null) {
        throw const FormatException('Mirror patch has no revision pair.');
      }
    case ConversationMirrorEventKind.unwatched:
      break;
    case ConversationMirrorEventKind.error:
      if (message.error == null) {
        throw const FormatException('Mirror error has no message.');
      }
    case ConversationMirrorEventKind.unknown:
      break;
  }
}

class _ConversationMirrorListResult<T> {
  const _ConversationMirrorListResult({
    this.values = const [],
    this.malformedCount = 0,
  });

  final List<T> values;
  final int malformedCount;
}

_ConversationMirrorListResult<ConversationMirrorWireEntry>
_conversationMirrorEntryList(
  Object raw, {
  required int maximumLength,
}) {
  if (raw is! List) {
    throw const FormatException('Conversation mirror entries must be a list.');
  }
  if (raw.length > maximumLength) {
    throw const FormatException(
      'Conversation mirror entries exceed the safety bound.',
    );
  }
  final entries = <ConversationMirrorWireEntry>[];
  var malformedCount = 0;
  for (final candidate in raw) {
    if (candidate is! Map) {
      malformedCount++;
      continue;
    }
    try {
      final entry = ConversationMirrorWireEntry.fromJson(
        Map<String, dynamic>.from(candidate),
      );
      if (utf8.encode(jsonEncode(entry.rawMessage)).length >
          _conversationMirrorMaxEntryBytes) {
        throw const FormatException(
          'Conversation mirror entry exceeds the safety bound.',
        );
      }
      entries.add(entry);
    } catch (_) {
      // Keep malformed-item handling local to this list. The surrounding
      // frame still has strict identity, revision and page validation.
      malformedCount++;
    }
  }
  return _ConversationMirrorListResult(
    values: List.unmodifiable(entries),
    malformedCount: malformedCount,
  );
}

_ConversationMirrorListResult<String> _conversationMirrorStringList(
  Object? raw,
) {
  if (raw == null) return const _ConversationMirrorListResult<String>();
  if (raw is! List) {
    throw const FormatException('Conversation mirror deletes are invalid.');
  }
  if (raw.length > _conversationMirrorMaxInlineDeletes) {
    throw const FormatException(
      'Conversation mirror deletes exceed the safety bound.',
    );
  }
  final deletes = <String>[];
  var malformedCount = 0;
  for (final candidate in raw) {
    if (candidate is! String ||
        candidate.isEmpty ||
        candidate.length > _conversationMirrorMaxEntryIdLength) {
      malformedCount++;
      continue;
    }
    deletes.add(candidate);
  }
  return _ConversationMirrorListResult(
    values: List.unmodifiable(deletes),
    malformedCount: malformedCount,
  );
}

bool _conversationMirrorOptionalBool(
  Map<String, dynamic> json,
  String key, {
  required bool fallback,
}) {
  final value = json[key];
  return value is bool ? value : fallback;
}

String _conversationMirrorRequiredString(
  Map<String, dynamic> json,
  String key, {
  int? maximumLength,
}) {
  final value = json[key];
  if (value is! String ||
      value.trim().isEmpty ||
      (maximumLength != null && value.length > maximumLength)) {
    throw FormatException('Conversation mirror field $key is required.');
  }
  return value;
}

String? _conversationMirrorOptionalString(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Conversation mirror field $key is invalid.');
  }
  return value;
}

int _conversationMirrorRequiredInt(
  Map<String, dynamic> json,
  String key, {
  required int minimum,
}) {
  final value = _conversationMirrorOptionalInt(json, key, minimum: minimum);
  if (value == null) {
    throw FormatException('Conversation mirror field $key is required.');
  }
  return value;
}

int? _conversationMirrorOptionalInt(
  Map<String, dynamic> json,
  String key, {
  required int minimum,
}) {
  final raw = json[key];
  if (raw == null) return null;
  if (raw is! num || raw.toInt() != raw || raw.toInt() < minimum) {
    throw FormatException('Conversation mirror field $key is invalid.');
  }
  return raw.toInt();
}

String _conversationMirrorClientId(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
  return value;
}
