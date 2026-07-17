part of '../../messages.dart';

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
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => switch (json['type']) {
    'subagent_list' => SubagentListMessage.fromJson(json),
    'subagent_history' => SubagentHistoryMessage.fromJson(json),
    _ => null,
  };

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (type != 'get_subagents' && type != 'get_subagent_history') return null;
    final sessionId = request['sessionId'];
    final requestId = request['requestId'];
    if (sessionId is! String || requestId is! String) return null;
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: type as String,
      ownerSessionId: sessionId,
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
            response.sessionId == request.ownerSessionId &&
            response.requestId == request.requestId,
      'get_subagent_history' =>
        response is SubagentHistoryMessage &&
            response.sessionId == request.ownerSessionId &&
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

Map<String, dynamic>? _subagentStringKeyedMap(dynamic value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}
