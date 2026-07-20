part of '../../messages.dart';

const codexDesktopContinuityBridgeCapability = 'codex_desktop_continuity_v1';

const LocalFeatureProtocolSlot codexDesktopContinuityProtocolSlot =
    _CodexDesktopContinuityProtocolSlot();

class _CodexDesktopContinuityProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _CodexDesktopContinuityProtocolSlot();

  @override
  String get featureId => 'codex_desktop_continuity';

  @override
  List<String> get supportedServerMessageTypes => const [
    'codex_desktop_continuity_event_v1',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) {
    if (json['type'] != 'codex_desktop_continuity_event_v1') return null;
    return CodexDesktopContinuityEventMessage.fromJson(json);
  }

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (!const {
      'codex_desktop_continuity_watch',
      'codex_desktop_continuity_unwatch',
    }.contains(type)) {
      return null;
    }
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
    if (response is! CodexDesktopContinuityEventMessage ||
        response.sessionId != request.ownerSessionId ||
        response.requestId != request.requestId) {
      return false;
    }
    if (response.event == CodexDesktopContinuityEventKind.error) return true;
    return switch (request.requestType) {
      'codex_desktop_continuity_watch' =>
        response.event == CodexDesktopContinuityEventKind.watching,
      'codex_desktop_continuity_unwatch' =>
        response.event == CodexDesktopContinuityEventKind.unwatched,
      _ => false,
    };
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) {
    if (error.errorCode == 'unsupported_capability' &&
        error.message ==
            'Codex Desktop continuity capability was not negotiated') {
      return true;
    }
    final message = error.message.toLowerCase();
    return message.contains(request.requestType.toLowerCase()) &&
        RegExp(
          r'\b(unknown|unsupported|unrecognized)\b|not supported|invalid message type',
        ).hasMatch(message);
  }
}

enum CodexDesktopContinuityEventKind {
  watching('watching'),
  state('state'),
  message('message'),
  unwatched('unwatched'),
  error('error'),
  unknown('__unknown__');

  final String wireValue;
  const CodexDesktopContinuityEventKind(this.wireValue);

  static CodexDesktopContinuityEventKind parse(Object? value) {
    for (final event in values) {
      if (event.wireValue == value) return event;
    }
    return unknown;
  }
}

enum CodexDesktopContinuityState {
  idle('idle'),
  running('running'),
  unknown('unknown');

  final String wireValue;
  const CodexDesktopContinuityState(this.wireValue);

  static CodexDesktopContinuityState parse(Object? value) => switch (value) {
    'idle' => idle,
    'running' => running,
    _ => unknown,
  };
}

class CodexDesktopContinuityEventMessage
    implements LocalFeatureTransientMessage {
  @override
  String get featureId => 'codex_desktop_continuity';

  final CodexDesktopContinuityEventKind event;
  final String requestId;
  final String bridgeInstanceId;
  @override
  final String sessionId;
  final String threadId;
  final String origin;
  final CodexDesktopContinuityState? state;
  final String? turnId;
  final String? outcome;
  final bool handoffQueued;
  final String? timestamp;
  final String? itemKey;
  final ServerMessage? payload;
  final String? errorCode;
  final String? error;

  const CodexDesktopContinuityEventMessage({
    required this.event,
    required this.requestId,
    required this.bridgeInstanceId,
    required this.sessionId,
    required this.threadId,
    required this.origin,
    this.state,
    this.turnId,
    this.outcome,
    this.handoffQueued = false,
    this.timestamp,
    this.itemKey,
    this.payload,
    this.errorCode,
    this.error,
  });

  factory CodexDesktopContinuityEventMessage.fromJson(
    Map<String, dynamic> json,
  ) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Desktop continuity $key must be a string.');
      }
      return value;
    }

    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String || value.isEmpty) {
        throw FormatException('Desktop continuity $key must be a string.');
      }
      return value;
    }

    final event = CodexDesktopContinuityEventKind.parse(json['event']);
    final rawPayload = json['message'];
    if (rawPayload != null && rawPayload is! Map) {
      throw const FormatException(
        'Desktop continuity message payload must be a map.',
      );
    }
    final message = CodexDesktopContinuityEventMessage(
      event: event,
      requestId: requiredString('requestId'),
      bridgeInstanceId: requiredString('bridgeInstanceId'),
      sessionId: requiredString('sessionId'),
      threadId: requiredString('threadId'),
      origin: requiredString('origin'),
      state: json['state'] == null
          ? null
          : CodexDesktopContinuityState.parse(json['state']),
      turnId: optionalString('turnId'),
      outcome: optionalString('outcome'),
      handoffQueued: json['handoffQueued'] as bool? ?? false,
      timestamp: optionalString('timestamp'),
      itemKey: optionalString('itemKey'),
      payload: rawPayload == null
          ? null
          : ServerMessage.fromJson(Map<String, dynamic>.from(rawPayload)),
      errorCode: optionalString('errorCode'),
      error: optionalString('error'),
    );
    _validateCodexDesktopContinuityEvent(message);
    return message;
  }
}

ClientMessage requestCodexDesktopContinuityWatch({
  required String requestId,
  required String sessionId,
  required String threadId,
  required String projectPath,
}) => _codexDesktopContinuityRequest(
  type: 'codex_desktop_continuity_watch',
  requestId: requestId,
  sessionId: sessionId,
  threadId: threadId,
  projectPath: projectPath,
);

ClientMessage requestCodexDesktopContinuityUnwatch({
  required String requestId,
  required String sessionId,
  required String threadId,
}) => _codexDesktopContinuityRequest(
  type: 'codex_desktop_continuity_unwatch',
  requestId: requestId,
  sessionId: sessionId,
  threadId: threadId,
);

ClientMessage _codexDesktopContinuityRequest({
  required String type,
  required String requestId,
  required String sessionId,
  required String threadId,
  String? projectPath,
}) {
  String checked(String value, String name, int maxLength) {
    if (value.trim().isEmpty || value.length > maxLength) {
      throw ArgumentError.value(value, name, 'must be non-empty and bounded');
    }
    return value;
  }

  if (projectPath != null &&
      (projectPath.trim().isEmpty || projectPath.length > 4096)) {
    throw ArgumentError.value(projectPath, 'projectPath', 'is invalid');
  }
  return ClientMessage._(<String, dynamic>{
    'type': type,
    'protocolVersion': 1,
    'requestId': checked(requestId, 'requestId', 128),
    'sessionId': checked(sessionId, 'sessionId', 256),
    'threadId': checked(threadId, 'threadId', 256),
    'projectPath': ?projectPath,
  }, delivery: ClientMessageDelivery.ephemeral);
}

void _validateCodexDesktopContinuityEvent(
  CodexDesktopContinuityEventMessage message,
) {
  if (message.origin != 'desktop_rollout') {
    throw FormatException(
      'Unsupported Desktop continuity origin: ${message.origin}',
    );
  }
  switch (message.event) {
    case CodexDesktopContinuityEventKind.watching:
      if (message.state == null) {
        throw const FormatException('Watching requires state.');
      }
      break;
    case CodexDesktopContinuityEventKind.state:
      if (message.state != CodexDesktopContinuityState.idle &&
          message.state != CodexDesktopContinuityState.running) {
        throw const FormatException('State event requires idle or running.');
      }
      break;
    case CodexDesktopContinuityEventKind.message:
      if (message.itemKey == null || message.payload == null) {
        throw const FormatException(
          'Message event requires itemKey and payload.',
        );
      }
      break;
    case CodexDesktopContinuityEventKind.error:
      if (message.errorCode == null || message.error == null) {
        throw const FormatException('Error event requires error details.');
      }
      break;
    case CodexDesktopContinuityEventKind.unwatched:
      break;
    case CodexDesktopContinuityEventKind.unknown:
      throw const FormatException('Unknown Desktop continuity event.');
  }
}
