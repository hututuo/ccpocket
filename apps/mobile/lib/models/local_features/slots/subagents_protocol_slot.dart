part of '../../messages.dart';

const detachedSubagentsReadCapability = 'detached_subagents_read_v1';

const LocalFeatureProtocolSlot subagentsProtocolSlot = _SubagentsProtocolSlot();

class _SubagentsProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _SubagentsProtocolSlot();

  @override
  String get featureId => 'subagents';

  @override
  List<String> get supportedServerMessageTypes => const [
    'subagent_list',
    'subagent_history',
    'detached_subagent_list',
    'detached_subagent_history',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => switch (json['type']) {
    'subagent_list' => SubagentListMessage.fromJson(json),
    'subagent_history' => SubagentHistoryMessage.fromJson(json),
    'detached_subagent_list' => DetachedSubagentListMessage.fromJson(json),
    'detached_subagent_history' => DetachedSubagentHistoryMessage.fromJson(
      json,
    ),
    _ => null,
  };

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (type != 'get_subagents' &&
        type != 'get_subagent_history' &&
        type != 'get_detached_subagents' &&
        type != 'get_detached_subagent_history') {
      return null;
    }
    final ownerSessionId =
        type == 'get_detached_subagents' ||
            type == 'get_detached_subagent_history'
        ? request['ownerSessionId']
        : request['sessionId'];
    final requestId = request['requestId'];
    if (ownerSessionId is! String || requestId is! String) return null;
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
  ) {
    return switch (request.requestType) {
      'get_subagents' =>
        response is SubagentListMessage &&
            response is! DetachedSubagentListMessage &&
            response.sessionId == request.ownerSessionId &&
            response.requestId == request.requestId,
      'get_subagent_history' =>
        response is SubagentHistoryMessage &&
            response is! DetachedSubagentHistoryMessage &&
            response.sessionId == request.ownerSessionId &&
            response.requestId == request.requestId,
      'get_detached_subagents' =>
        response is DetachedSubagentListMessage &&
            response.ownerSessionId == request.ownerSessionId &&
            response.requestId == request.requestId,
      'get_detached_subagent_history' =>
        response is DetachedSubagentHistoryMessage &&
            response.ownerSessionId == request.ownerSessionId &&
            response.requestId == request.requestId,
      _ => false,
    };
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) => false;
}

ClientMessage requestSubagents({
  required String sessionId,
  required String requestId,
}) {
  _requireSubagentId(sessionId, 'sessionId', 256);
  _requireSubagentId(requestId, 'requestId', 128);
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'get_subagents',
    sessionId: sessionId,
    requestId: requestId,
  );
}

ClientMessage requestSubagentHistory({
  required String sessionId,
  required String threadId,
  required String requestId,
}) {
  _requireSubagentId(sessionId, 'sessionId', 256);
  _requireSubagentId(threadId, 'threadId', 256);
  _requireSubagentId(requestId, 'requestId', 128);
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'get_subagent_history',
    sessionId: sessionId,
    requestId: requestId,
    fields: {'threadId': threadId},
  );
}

ClientMessage requestDetachedSubagents({
  required String ownerSessionId,
  required String providerThreadId,
  required String codexSourceId,
  required String requestId,
}) {
  _requireSubagentId(ownerSessionId, 'ownerSessionId', 256);
  _requireSubagentId(providerThreadId, 'providerThreadId', 256);
  _requireSubagentId(codexSourceId, 'codexSourceId', 256);
  _requireSubagentId(requestId, 'requestId', 128);
  return ClientMessage._(<String, dynamic>{
    'type': 'get_detached_subagents',
    'ownerSessionId': ownerSessionId,
    'providerThreadId': providerThreadId,
    'codexSourceId': codexSourceId,
    'requestId': requestId,
  }, delivery: ClientMessageDelivery.ephemeral);
}

ClientMessage requestDetachedSubagentHistory({
  required String ownerSessionId,
  required String providerThreadId,
  required String codexSourceId,
  required String threadId,
  required String requestId,
}) {
  _requireSubagentId(ownerSessionId, 'ownerSessionId', 256);
  _requireSubagentId(providerThreadId, 'providerThreadId', 256);
  _requireSubagentId(codexSourceId, 'codexSourceId', 256);
  _requireSubagentId(threadId, 'threadId', 256);
  _requireSubagentId(requestId, 'requestId', 128);
  return ClientMessage._(<String, dynamic>{
    'type': 'get_detached_subagent_history',
    'ownerSessionId': ownerSessionId,
    'providerThreadId': providerThreadId,
    'codexSourceId': codexSourceId,
    'threadId': threadId,
    'requestId': requestId,
  }, delivery: ClientMessageDelivery.ephemeral);
}

void _requireSubagentId(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
}

class SubagentListMessage implements LocalFeatureTransientMessage {
  @override
  final String? sessionId;
  final String requestId;
  final List<SubagentInfo> subagents;
  final bool truncated;
  final String? error;

  const SubagentListMessage({
    this.sessionId,
    required this.requestId,
    required this.subagents,
    this.truncated = false,
    this.error,
  });

  @override
  String get featureId => 'subagents';

  factory SubagentListMessage.fromJson(Map<String, dynamic> json) {
    final rawSubagents = json['subagents'] ?? json['agents'];
    final sessionId = _subagentNonEmptyString(json['sessionId']);
    final requestId = _subagentNonEmptyString(json['requestId']);
    if (sessionId == null || requestId == null) {
      throw const FormatException(
        'subagent_list requires non-empty sessionId and requestId',
      );
    }
    return SubagentListMessage(
      sessionId: sessionId,
      requestId: requestId,
      subagents:
          (rawSubagents as List?)
              ?.whereType<Map>()
              .map(
                (item) =>
                    SubagentInfo.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((agent) => agent.threadId.isNotEmpty)
              .toList(growable: false) ??
          const <SubagentInfo>[],
      truncated: json['truncated'] == true,
      error: _subagentNonEmptyString(json['error']),
    );
  }
}

class SubagentHistoryMessage implements LocalFeatureTransientMessage {
  @override
  final String? sessionId;
  final String requestId;
  final String threadId;
  final SubagentInfo? subagent;
  final List<ServerMessage> messages;
  final bool truncated;
  final String? error;

  const SubagentHistoryMessage({
    this.sessionId,
    required this.requestId,
    required this.threadId,
    this.subagent,
    required this.messages,
    this.truncated = false,
    this.error,
  });

  @override
  String get featureId => 'subagents';

  factory SubagentHistoryMessage.fromJson(Map<String, dynamic> json) {
    final rawSubagent = _subagentStringKeyedMap(
      json['subagent'] ?? json['agent'],
    );
    final sessionId = _subagentNonEmptyString(json['sessionId']);
    final requestId = _subagentNonEmptyString(json['requestId']);
    final threadId =
        _subagentNonEmptyString(json['threadId']) ??
        (rawSubagent == null
            ? null
            : _subagentNonEmptyString(rawSubagent['threadId']));
    if (sessionId == null || requestId == null || threadId == null) {
      throw const FormatException(
        'subagent_history requires non-empty sessionId, requestId, and threadId',
      );
    }
    return SubagentHistoryMessage(
      sessionId: sessionId,
      requestId: requestId,
      threadId: threadId,
      subagent: rawSubagent == null ? null : SubagentInfo.fromJson(rawSubagent),
      messages:
          (json['messages'] as List?)
              ?.whereType<Map>()
              .map(
                (message) =>
                    ServerMessage.fromJson(Map<String, dynamic>.from(message)),
              )
              .toList(growable: false) ??
          const <ServerMessage>[],
      truncated: json['truncated'] == true,
      error: _subagentNonEmptyString(json['error']),
    );
  }
}

/// A detached provider response routed through [ownerSessionId].
///
/// The inherited `sessionId` is only the Mobile pane's stream owner. It is
/// never a Bridge runtime-session identifier.
class DetachedSubagentListMessage extends SubagentListMessage {
  final String ownerSessionId;
  final String providerThreadId;
  final String? codexSourceId;
  final String? errorCode;

  const DetachedSubagentListMessage({
    required this.ownerSessionId,
    required this.providerThreadId,
    this.codexSourceId,
    required super.requestId,
    required super.subagents,
    super.truncated,
    super.error,
    this.errorCode,
  }) : super(sessionId: ownerSessionId);

  factory DetachedSubagentListMessage.fromJson(Map<String, dynamic> json) {
    final ownerSessionId = _subagentBoundedWireId(json['ownerSessionId'], 256);
    final providerThreadId = _subagentBoundedWireId(
      json['providerThreadId'],
      256,
    );
    final codexSourceId = _subagentBoundedWireId(json['codexSourceId'], 256);
    final requestId = _subagentBoundedWireId(json['requestId'], 128);
    final error = _subagentNonEmptyString(json['error']);
    if (ownerSessionId == null ||
        providerThreadId == null ||
        requestId == null ||
        (error == null && codexSourceId == null)) {
      throw const FormatException(
        'detached_subagent_list requires bounded owner, provider, request, '
        'and successful source identities',
      );
    }
    final rawSubagents = json['subagents'] ?? json['agents'];
    return DetachedSubagentListMessage(
      ownerSessionId: ownerSessionId,
      providerThreadId: providerThreadId,
      codexSourceId: codexSourceId,
      requestId: requestId,
      subagents:
          (rawSubagents as List?)
              ?.whereType<Map>()
              .map(
                (item) =>
                    SubagentInfo.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((agent) => agent.threadId.isNotEmpty)
              .toList(growable: false) ??
          const <SubagentInfo>[],
      truncated: json['truncated'] == true,
      error: error,
      errorCode: _subagentNonEmptyString(json['errorCode']),
    );
  }
}

/// A detached provider-history response routed through [ownerSessionId].
class DetachedSubagentHistoryMessage extends SubagentHistoryMessage {
  final String ownerSessionId;
  final String providerThreadId;
  final String? codexSourceId;
  final String? errorCode;

  const DetachedSubagentHistoryMessage({
    required this.ownerSessionId,
    required this.providerThreadId,
    this.codexSourceId,
    required super.requestId,
    required super.threadId,
    super.subagent,
    required super.messages,
    super.truncated,
    super.error,
    this.errorCode,
  }) : super(sessionId: ownerSessionId);

  factory DetachedSubagentHistoryMessage.fromJson(Map<String, dynamic> json) {
    final ownerSessionId = _subagentBoundedWireId(json['ownerSessionId'], 256);
    final providerThreadId = _subagentBoundedWireId(
      json['providerThreadId'],
      256,
    );
    final codexSourceId = _subagentBoundedWireId(json['codexSourceId'], 256);
    final requestId = _subagentBoundedWireId(json['requestId'], 128);
    final error = _subagentNonEmptyString(json['error']);
    final rawSubagent = _subagentStringKeyedMap(
      json['subagent'] ?? json['agent'],
    );
    final threadId =
        _subagentBoundedWireId(json['threadId'], 256) ??
        (rawSubagent == null
            ? null
            : _subagentBoundedWireId(rawSubagent['threadId'], 256));
    if (ownerSessionId == null ||
        providerThreadId == null ||
        requestId == null ||
        threadId == null ||
        (error == null && codexSourceId == null)) {
      throw const FormatException(
        'detached_subagent_history requires bounded owner, provider, request, '
        'thread, and successful source identities',
      );
    }
    return DetachedSubagentHistoryMessage(
      ownerSessionId: ownerSessionId,
      providerThreadId: providerThreadId,
      codexSourceId: codexSourceId,
      requestId: requestId,
      threadId: threadId,
      subagent: rawSubagent == null ? null : SubagentInfo.fromJson(rawSubagent),
      messages:
          (json['messages'] as List?)
              ?.whereType<Map>()
              .map(
                (message) =>
                    ServerMessage.fromJson(Map<String, dynamic>.from(message)),
              )
              .toList(growable: false) ??
          const <ServerMessage>[],
      truncated: json['truncated'] == true,
      error: error,
      errorCode: _subagentNonEmptyString(json['errorCode']),
    );
  }
}

String? _subagentBoundedWireId(dynamic value, int maxLength) {
  final normalized = _subagentNonEmptyString(value);
  return normalized == null || normalized.length > maxLength
      ? null
      : normalized;
}

Map<String, dynamic>? _subagentStringKeyedMap(dynamic value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}
