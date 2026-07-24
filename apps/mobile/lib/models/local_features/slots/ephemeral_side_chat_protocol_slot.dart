part of '../../messages.dart';

const ephemeralSideChatCapability = 'ephemeral_side_chat_v1';

const LocalFeatureProtocolSlot ephemeralSideChatProtocolSlot =
    _EphemeralSideChatProtocolSlot();

class _EphemeralSideChatProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _EphemeralSideChatProtocolSlot();

  @override
  String get featureId => 'ephemeral_side_chat';

  @override
  List<String> get supportedServerMessageTypes => const [
    'ephemeral_side_chat_opened',
    'ephemeral_side_chat_registry',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => switch (json['type']) {
    'ephemeral_side_chat_opened' => EphemeralSideChatOpenedMessage.fromJson(
      json,
    ),
    'ephemeral_side_chat_registry' => EphemeralSideChatRegistryMessage.fromJson(
      json,
    ),
    _ => null,
  };

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    final requestId = request['requestId'];
    if (requestId is! String) return null;
    final ownerSessionId = switch (type) {
      'open_ephemeral_side_chat' => request['parentSessionId'],
      'list_ephemeral_side_chats' => 'ephemeral-side-chat-registry',
      'close_ephemeral_side_chat' => request['childSessionId'],
      _ => null,
    };
    if (ownerSessionId is! String) return null;
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: type as String,
      ownerSessionId: ownerSessionId,
      requestId: requestId,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) => switch (request.requestType) {
    'open_ephemeral_side_chat' =>
      response is EphemeralSideChatOpenedMessage &&
          response.parentSessionId == request.ownerSessionId &&
          response.requestId == request.requestId,
    'list_ephemeral_side_chats' || 'close_ephemeral_side_chat' =>
      response is EphemeralSideChatRegistryMessage &&
          response.requestId == request.requestId,
    _ => false,
  };

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) => false;
}

class EphemeralSideChatEntry {
  final String childSessionId;
  final String parentSessionId;
  final String projectPath;
  final String? worktreePath;
  final String? worktreeBranch;
  final String? permissionMode;
  final String? sandboxMode;
  final String? approvalPolicy;
  final String? approvalsReviewer;
  final String status;
  final DateTime createdAt;
  final DateTime lastActivityAt;

  const EphemeralSideChatEntry({
    required this.childSessionId,
    required this.parentSessionId,
    required this.projectPath,
    this.worktreePath,
    this.worktreeBranch,
    this.permissionMode,
    this.sandboxMode,
    this.approvalPolicy,
    this.approvalsReviewer,
    required this.status,
    required this.createdAt,
    required this.lastActivityAt,
  });

  factory EphemeralSideChatEntry.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const [
      'childSessionId',
      'parentSessionId',
      'projectPath',
      'worktreePath',
      'worktreeBranch',
      'permissionMode',
      'sandboxMode',
      'approvalPolicy',
      'approvalsReviewer',
      'status',
      'createdAt',
      'lastActivityAt',
    ]);
    final createdAt = DateTime.tryParse(
      _sideChatRequiredString(json, 'createdAt'),
    );
    final lastActivityAt = DateTime.tryParse(
      _sideChatRequiredString(json, 'lastActivityAt'),
    );
    if (createdAt == null || lastActivityAt == null) {
      throw const FormatException(
        'Ephemeral side chat timestamps must be ISO-8601 values.',
      );
    }
    return EphemeralSideChatEntry(
      childSessionId: _sideChatRequiredString(json, 'childSessionId'),
      parentSessionId: _sideChatRequiredString(json, 'parentSessionId'),
      projectPath: _sideChatRequiredString(json, 'projectPath'),
      worktreePath: _sideChatOptionalString(json, 'worktreePath'),
      worktreeBranch: _sideChatOptionalString(json, 'worktreeBranch'),
      permissionMode: _sideChatOptionalString(json, 'permissionMode'),
      sandboxMode: _sideChatOptionalString(json, 'sandboxMode'),
      approvalPolicy: _sideChatOptionalString(json, 'approvalPolicy'),
      approvalsReviewer: _sideChatOptionalString(json, 'approvalsReviewer'),
      status: _sideChatRequiredString(json, 'status'),
      createdAt: createdAt,
      lastActivityAt: lastActivityAt,
    );
  }
}

class EphemeralSideChatOpenedMessage implements LocalFeatureTransientMessage {
  final String parentSessionId;
  final String requestId;
  final EphemeralSideChatEntry? entry;
  final String? error;
  final String? errorCode;

  const EphemeralSideChatOpenedMessage({
    required this.parentSessionId,
    required this.requestId,
    this.entry,
    this.error,
    this.errorCode,
  });

  @override
  String get featureId => 'ephemeral_side_chat';

  @override
  String get sessionId => parentSessionId;

  bool get isSuccess => entry != null && error == null;

  factory EphemeralSideChatOpenedMessage.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const [
      'type',
      'parentSessionId',
      'requestId',
      'entry',
      'error',
      'errorCode',
    ]);
    final rawEntry = json['entry'];
    if (rawEntry != null && rawEntry is! Map) {
      throw const FormatException('Ephemeral side chat entry must be a map.');
    }
    final entry = rawEntry == null
        ? null
        : EphemeralSideChatEntry.fromJson(
            Map<String, dynamic>.from(rawEntry as Map),
          );
    final error = _sideChatOptionalString(json, 'error');
    if ((entry == null) == (error == null)) {
      throw const FormatException(
        'Ephemeral side chat response must contain exactly one result.',
      );
    }
    final parentSessionId = _sideChatRequiredString(json, 'parentSessionId');
    if (entry != null && entry.parentSessionId != parentSessionId) {
      throw const FormatException(
        'Ephemeral side chat response parent does not match its entry.',
      );
    }
    return EphemeralSideChatOpenedMessage(
      parentSessionId: parentSessionId,
      requestId: _sideChatRequiredString(json, 'requestId'),
      entry: entry,
      error: error,
      errorCode: _sideChatOptionalString(json, 'errorCode'),
    );
  }
}

class EphemeralSideChatRegistryMessage implements LocalFeatureTransientMessage {
  final String? requestId;
  final List<EphemeralSideChatEntry>? entries;
  final String? error;
  final String? errorCode;

  const EphemeralSideChatRegistryMessage({
    this.requestId,
    this.entries,
    this.error,
    this.errorCode,
  });

  @override
  String get featureId => 'ephemeral_side_chat';

  @override
  String? get sessionId => null;

  bool get isSuccess => entries != null && error == null;

  factory EphemeralSideChatRegistryMessage.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const [
      'type',
      'requestId',
      'entries',
      'error',
      'errorCode',
    ]);
    final rawEntries = json['entries'];
    if (rawEntries != null && rawEntries is! List) {
      throw const FormatException(
        'Ephemeral side chat registry entries must be a list.',
      );
    }
    final entries = rawEntries == null
        ? null
        : List<EphemeralSideChatEntry>.unmodifiable(
            rawEntries.map((raw) {
              if (raw is! Map) {
                throw const FormatException(
                  'Ephemeral side chat registry entry must be a map.',
                );
              }
              return EphemeralSideChatEntry.fromJson(
                Map<String, dynamic>.from(raw),
              );
            }),
          );
    final error = _sideChatOptionalString(json, 'error');
    if ((entries == null) == (error == null)) {
      throw const FormatException(
        'Ephemeral side chat registry must contain exactly one result.',
      );
    }
    return EphemeralSideChatRegistryMessage(
      requestId: _sideChatOptionalString(json, 'requestId'),
      entries: entries,
      error: error,
      errorCode: _sideChatOptionalString(json, 'errorCode'),
    );
  }
}

ClientMessage requestOpenEphemeralSideChat({
  required String parentSessionId,
  required String requestId,
}) => ClientMessage._(<String, dynamic>{
  'type': 'open_ephemeral_side_chat',
  'parentSessionId': _sideChatClientId(parentSessionId, 'parentSessionId', 256),
  'requestId': _sideChatClientId(requestId, 'requestId', 128),
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage requestListEphemeralSideChats({required String requestId}) =>
    ClientMessage._(<String, dynamic>{
      'type': 'list_ephemeral_side_chats',
      'requestId': _sideChatClientId(requestId, 'requestId', 128),
    }, delivery: ClientMessageDelivery.ephemeral);

ClientMessage requestCloseEphemeralSideChat({
  required String childSessionId,
  required String requestId,
}) => ClientMessage._(<String, dynamic>{
  'type': 'close_ephemeral_side_chat',
  'childSessionId': _sideChatClientId(childSessionId, 'childSessionId', 256),
  'requestId': _sideChatClientId(requestId, 'requestId', 128),
}, delivery: ClientMessageDelivery.ephemeral);
