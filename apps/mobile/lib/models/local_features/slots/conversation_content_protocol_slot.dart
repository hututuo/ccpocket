part of '../../messages.dart';

const conversationContentEventCapability = 'conversation_content_event_v1';
const _conversationContentMaxEntries = 2000;
const _conversationContentMaxPageEntries = 32;
const _conversationContentMaxPages = 2000;

const LocalFeatureProtocolSlot conversationContentProtocolSlot =
    _ConversationContentProtocolSlot();

class _ConversationContentProtocolSlot implements LocalFeatureProtocolSlot {
  const _ConversationContentProtocolSlot();

  @override
  String get featureId => 'conversation_content';

  @override
  List<String> get supportedServerMessageTypes => const [
    conversationContentEventCapability,
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) {
    if (json['type'] != conversationContentEventCapability) return null;
    return ConversationContentEventMessage.fromJson(json);
  }
}

enum ConversationContentEventKind {
  subscribed('subscribed'),
  focusApplied('focus_applied'),
  unsubscribed('unsubscribed'),
  snapshotBegin('snapshot_begin'),
  snapshotPage('snapshot_page'),
  snapshotComplete('snapshot_complete'),
  patch('patch'),
  error('error');

  const ConversationContentEventKind(this.wireValue);

  final String wireValue;

  static ConversationContentEventKind parse(Object? value) {
    for (final event in values) {
      if (event.wireValue == value) return event;
    }
    throw FormatException('Unsupported conversation content event: $value');
  }
}

class ConversationContentTarget {
  const ConversationContentTarget({
    required this.provider,
    required this.providerSessionId,
  });

  final String provider;
  final String providerSessionId;

  String get key => '$provider\u0000$providerSessionId';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'providerSessionId': providerSessionId,
  };
}

class ConversationContentCursor extends ConversationContentTarget {
  const ConversationContentCursor({
    required super.provider,
    required super.providerSessionId,
    required this.revision,
    this.windowComplete = true,
  });

  final String revision;
  final bool windowComplete;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...super.toJson(),
    'revision': revision,
  };
}

class ConversationContentWireEntry {
  const ConversationContentWireEntry({
    required this.entryId,
    required this.index,
    required this.contentHash,
    required this.rawMessage,
  });

  final String entryId;
  final int index;
  final String contentHash;
  final Map<String, dynamic> rawMessage;

  ServerMessage decodeMessage() => ServerMessage.fromJson(rawMessage);

  factory ConversationContentWireEntry.fromJson(Map<String, dynamic> json) {
    final rawMessage = json['message'];
    if (rawMessage is! Map) {
      throw const FormatException(
        'Conversation content message must be a map.',
      );
    }
    // Decoding stays lazy (same as ConversationMirrorWireEntry): eagerly
    // decoding thousands of entries here blocks the main thread, and one
    // undecodable entry would reject the whole frame instead of only
    // invalidating the window that contains it.
    return ConversationContentWireEntry(
      entryId: _conversationContentRequiredString(
        json,
        'entryId',
        maximumLength: 512,
      ),
      index: _conversationContentRequiredInt(json, 'index', minimum: 0),
      contentHash: _conversationContentRequiredString(
        json,
        'contentHash',
        maximumLength: 128,
      ),
      rawMessage: Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(rawMessage),
      ),
    );
  }
}

class ConversationContentEventMessage implements LocalFeatureTransientMessage {
  const ConversationContentEventMessage({
    required this.event,
    required this.subscriptionId,
    required this.bridgeInstanceId,
    this.requestId,
    this.provider,
    this.providerSessionId,
    this.revision,
    this.baseRevision,
    this.entryCount,
    this.pageIndex,
    this.pageCount,
    this.hasEarlier,
    this.sourceEntryCount,
    this.hotConversationLimit,
    this.entries = const [],
    this.deletes = const [],
    this.focused,
    this.errorCode,
    this.error,
  });

  @override
  String get featureId => 'conversation_content';

  final ConversationContentEventKind event;
  final String subscriptionId;
  final String bridgeInstanceId;
  final String? requestId;
  final String? provider;
  final String? providerSessionId;
  final String? revision;
  final String? baseRevision;
  final int? entryCount;
  final int? pageIndex;
  final int? pageCount;
  final bool? hasEarlier;
  final int? sourceEntryCount;
  final int? hotConversationLimit;
  final List<ConversationContentWireEntry> entries;
  final List<String> deletes;
  final ConversationContentTarget? focused;
  final String? errorCode;
  final String? error;

  @override
  String? get sessionId => providerSessionId;

  factory ConversationContentEventMessage.fromJson(Map<String, dynamic> json) {
    final event = ConversationContentEventKind.parse(json['event']);
    final provider = _conversationContentOptionalProvider(json['provider']);
    final providerSessionId = _conversationContentOptionalString(
      json,
      'providerSessionId',
      maximumLength: 256,
    );
    final rawEntries = json['entries'];
    if (rawEntries != null && rawEntries is! List) {
      throw const FormatException(
        'Conversation content entries must be a list.',
      );
    }
    if (rawEntries is List &&
        rawEntries.length >
            (event == ConversationContentEventKind.snapshotPage
                ? _conversationContentMaxPageEntries
                : _conversationContentMaxEntries)) {
      throw const FormatException(
        'Conversation content entries exceed the safety bound.',
      );
    }
    final entries = rawEntries == null
        ? const <ConversationContentWireEntry>[]
        : List<ConversationContentWireEntry>.unmodifiable(
            rawEntries.whereType<Map>().map(
              (entry) => ConversationContentWireEntry.fromJson(
                Map<String, dynamic>.from(entry),
              ),
            ),
          );
    if (rawEntries is List && entries.length != rawEntries.length) {
      throw const FormatException(
        'Conversation content entries contain an invalid value.',
      );
    }
    final rawDeletes = json['deletes'];
    if (rawDeletes != null && rawDeletes is! List) {
      throw const FormatException(
        'Conversation content deletes must be a list.',
      );
    }
    if (rawDeletes is List &&
        rawDeletes.length > _conversationContentMaxEntries) {
      throw const FormatException(
        'Conversation content deletes exceed the safety bound.',
      );
    }
    final deletes = rawDeletes == null
        ? const <String>[]
        : List<String>.unmodifiable(rawDeletes.whereType<String>());
    if (rawDeletes is List && deletes.length != rawDeletes.length) {
      throw const FormatException(
        'Conversation content deletes contain an invalid value.',
      );
    }
    final rawFocused = json['focused'];
    if (rawFocused != null && rawFocused is! Map) {
      throw const FormatException(
        'Conversation content focused target must be a map.',
      );
    }
    final focused = rawFocused == null
        ? null
        : _conversationContentTargetFromJson(
            Map<String, dynamic>.from(rawFocused as Map),
          );

    final message = ConversationContentEventMessage(
      event: event,
      subscriptionId: _conversationContentRequiredString(
        json,
        'subscriptionId',
        maximumLength: 128,
      ),
      bridgeInstanceId: _conversationContentRequiredString(
        json,
        'bridgeInstanceId',
        maximumLength: 256,
      ),
      requestId: _conversationContentOptionalString(
        json,
        'requestId',
        maximumLength: 128,
      ),
      provider: provider,
      providerSessionId: providerSessionId,
      revision: _conversationContentOptionalString(
        json,
        'revision',
        maximumLength: 128,
      ),
      baseRevision: _conversationContentOptionalString(
        json,
        'baseRevision',
        maximumLength: 128,
      ),
      entryCount: _conversationContentOptionalInt(
        json,
        'entryCount',
        minimum: 0,
      ),
      pageIndex: _conversationContentOptionalInt(json, 'pageIndex', minimum: 0),
      pageCount: _conversationContentOptionalInt(json, 'pageCount', minimum: 0),
      hasEarlier: _conversationContentOptionalBool(json, 'hasEarlier'),
      sourceEntryCount: _conversationContentOptionalInt(
        json,
        'sourceEntryCount',
        minimum: 0,
      ),
      hotConversationLimit: _conversationContentOptionalInt(
        json,
        'hotConversationLimit',
        minimum: 1,
      ),
      entries: entries,
      deletes: deletes,
      focused: focused,
      errorCode: _conversationContentOptionalString(
        json,
        'errorCode',
        maximumLength: 128,
      ),
      error: _conversationContentOptionalString(
        json,
        'error',
        maximumLength: 2048,
      ),
    );
    _validateConversationContentEvent(message);
    return message;
  }
}

ClientMessage conversationContentSubscribe({
  required String requestId,
  required List<ConversationContentCursor> knownRevisions,
  ConversationContentTarget? focused,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_content_subscribe',
  'protocolVersion': 1,
  'requestId': requestId,
  'knownRevisions': knownRevisions
      .take(256)
      .map((cursor) => cursor.toJson())
      .toList(growable: false),
  'focused': ?focused?.toJson(),
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationContentFocus({
  required String requestId,
  required String subscriptionId,
  ConversationContentTarget? focused,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_content_focus',
  'protocolVersion': 1,
  'requestId': requestId,
  'subscriptionId': subscriptionId,
  'focused': ?focused?.toJson(),
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationContentAck({
  required String subscriptionId,
  required ConversationContentCursor cursor,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_content_ack',
  'protocolVersion': 1,
  'subscriptionId': subscriptionId,
  ...cursor.toJson(),
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationContentUnsubscribe({
  required String requestId,
  required String subscriptionId,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_content_unsubscribe',
  'protocolVersion': 1,
  'requestId': requestId,
  'subscriptionId': subscriptionId,
}, delivery: ClientMessageDelivery.ephemeral);

void _validateConversationContentEvent(
  ConversationContentEventMessage message,
) {
  final hasTarget =
      message.provider != null && message.providerSessionId != null;
  final targetFieldsMatch =
      (message.provider == null) == (message.providerSessionId == null);
  if (!targetFieldsMatch) {
    throw const FormatException(
      'Conversation content target must be complete.',
    );
  }
  switch (message.event) {
    case ConversationContentEventKind.subscribed:
      if (message.requestId == null || message.hotConversationLimit == null) {
        throw const FormatException(
          'Conversation content subscribed event is incomplete.',
        );
      }
    case ConversationContentEventKind.focusApplied:
    case ConversationContentEventKind.unsubscribed:
      if (message.requestId == null) {
        throw const FormatException(
          'Conversation content response requestId is missing.',
        );
      }
    case ConversationContentEventKind.snapshotBegin:
      if (!hasTarget ||
          message.revision == null ||
          message.entryCount == null ||
          message.pageCount == null ||
          message.entryCount! > _conversationContentMaxEntries ||
          message.pageCount! > _conversationContentMaxPages ||
          message.hasEarlier == null ||
          message.sourceEntryCount == null) {
        throw const FormatException(
          'Conversation content snapshot begin is incomplete.',
        );
      }
    case ConversationContentEventKind.snapshotPage:
      if (!hasTarget ||
          message.revision == null ||
          message.pageIndex == null ||
          message.pageCount == null ||
          message.pageCount! < 1 ||
          message.pageCount! > _conversationContentMaxPages ||
          message.pageIndex! >= message.pageCount!) {
        throw const FormatException(
          'Conversation content snapshot page is incomplete.',
        );
      }
    case ConversationContentEventKind.snapshotComplete:
      if (!hasTarget ||
          message.revision == null ||
          message.entryCount == null ||
          message.entryCount! > _conversationContentMaxEntries ||
          message.hasEarlier == null ||
          message.sourceEntryCount == null) {
        throw const FormatException(
          'Conversation content snapshot complete is incomplete.',
        );
      }
    case ConversationContentEventKind.patch:
      if (!hasTarget ||
          message.baseRevision == null ||
          message.revision == null ||
          message.hasEarlier == null ||
          message.sourceEntryCount == null) {
        throw const FormatException(
          'Conversation content patch is incomplete.',
        );
      }
      if (message.deletes.toSet().length != message.deletes.length ||
          message.entries.map((entry) => entry.entryId).toSet().length !=
              message.entries.length) {
        throw const FormatException(
          'Conversation content patch contains duplicate entries.',
        );
      }
    case ConversationContentEventKind.error:
      if (message.errorCode == null || message.error == null) {
        throw const FormatException(
          'Conversation content error event is incomplete.',
        );
      }
  }
}

ConversationContentTarget _conversationContentTargetFromJson(
  Map<String, dynamic> json,
) {
  return ConversationContentTarget(
    provider: _conversationContentRequiredProvider(json['provider']),
    providerSessionId: _conversationContentRequiredString(
      json,
      'providerSessionId',
      maximumLength: 256,
    ),
  );
}

String _conversationContentRequiredProvider(Object? value) {
  if (value != 'claude' && value != 'codex') {
    throw FormatException('Unsupported conversation content provider: $value');
  }
  return value! as String;
}

String? _conversationContentOptionalProvider(Object? value) {
  if (value == null) return null;
  return _conversationContentRequiredProvider(value);
}

String _conversationContentRequiredString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maximumLength) {
    throw FormatException('Conversation content $key must be a string.');
  }
  return value;
}

String? _conversationContentOptionalString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  if (json[key] == null) return null;
  return _conversationContentRequiredString(
    json,
    key,
    maximumLength: maximumLength,
  );
}

int _conversationContentRequiredInt(
  Map<String, dynamic> json,
  String key, {
  required int minimum,
}) {
  final value = json[key];
  if (value is! int || value < minimum) {
    throw FormatException('Conversation content $key must be an integer.');
  }
  return value;
}

int? _conversationContentOptionalInt(
  Map<String, dynamic> json,
  String key, {
  required int minimum,
}) {
  if (json[key] == null) return null;
  return _conversationContentRequiredInt(json, key, minimum: minimum);
}

bool? _conversationContentOptionalBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) {
    throw FormatException('Conversation content $key must be a boolean.');
  }
  return value;
}
