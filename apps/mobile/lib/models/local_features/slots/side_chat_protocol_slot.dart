part of '../../messages.dart';

const LocalFeatureProtocolSlot sideChatProtocolSlot = _SideChatProtocolSlot();

class _SideChatProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _SideChatProtocolSlot();

  @override
  String get featureId => 'side_chat';

  @override
  List<String> get supportedServerMessageTypes => const ['side_chat_event'];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) =>
      json['type'] == 'side_chat_event'
      ? SideChatEventMessage.fromJson(json)
      : null;

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (!const {
      'open_side_chat',
      'side_chat_input',
      'side_chat_permission_response',
      'side_chat_answer',
      'side_chat_interrupt',
      'close_side_chat',
    }.contains(type)) {
      return null;
    }
    final parentSessionId = request['parentSessionId'];
    final requestId = request['requestId'];
    if (parentSessionId is! String || requestId is! String) return null;
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: type as String,
      ownerSessionId: parentSessionId,
      requestId: requestId,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) {
    if (response is! SideChatEventMessage ||
        response.parentSessionId != request.ownerSessionId ||
        response.requestId != request.requestId) {
      return false;
    }
    return switch (request.requestType) {
      'open_side_chat' =>
        response.event == SideChatEventKind.opened ||
            response.event == SideChatEventKind.error,
      'side_chat_input' =>
        (response.event == SideChatEventKind.inputAccepted &&
                !response.queued) ||
            response.event == SideChatEventKind.error,
      'side_chat_permission_response' ||
      'side_chat_answer' ||
      'side_chat_interrupt' =>
        response.event == SideChatEventKind.status ||
            response.event == SideChatEventKind.error,
      'close_side_chat' =>
        response.event == SideChatEventKind.closed ||
            response.event == SideChatEventKind.error,
      _ => false,
    };
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) {
    return error.errorCode == 'unsupported_capability' &&
        error.message == 'Side chat capability was not negotiated';
  }
}

enum SideChatEventKind {
  opened('opened'),
  inputAccepted('input_accepted'),
  message('message'),
  status('status'),
  permissionRequest('permission_request'),
  question('question'),
  closed('closed'),
  error('error');

  final String wireValue;
  const SideChatEventKind(this.wireValue);

  static SideChatEventKind parse(Object? value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    throw FormatException('Unknown side chat event: $value');
  }
}

enum SideChatPermissionDecision {
  allow('allow'),
  allowAlways('allow_always'),
  deny('deny');

  final String wireValue;
  const SideChatPermissionDecision(this.wireValue);
}

class SideChatTranscriptMessage {
  final String id;
  final String role;
  final String text;

  const SideChatTranscriptMessage({
    required this.id,
    required this.role,
    required this.text,
  });

  factory SideChatTranscriptMessage.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const ['id', 'role', 'text']);
    final role = _sideChatRequiredString(json, 'role');
    if (!const {'user', 'assistant', 'tool', 'system'}.contains(role)) {
      throw FormatException('Invalid side chat message role: $role');
    }
    return SideChatTranscriptMessage(
      id: _sideChatRequiredString(json, 'id'),
      role: role,
      text: _sideChatRequiredString(json, 'text', allowEmpty: true),
    );
  }
}

class SideChatPermissionRequest {
  final String requestId;
  final String toolName;
  final Map<String, dynamic> input;

  const SideChatPermissionRequest({
    required this.requestId,
    required this.toolName,
    required this.input,
  });

  factory SideChatPermissionRequest.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const ['requestId', 'toolName', 'input']);
    final rawInput = json['input'];
    if (rawInput is! Map) {
      throw const FormatException('Side chat permission input must be a map.');
    }
    return SideChatPermissionRequest(
      requestId: _sideChatRequiredString(json, 'requestId'),
      toolName: _sideChatRequiredString(json, 'toolName'),
      input: Map<String, dynamic>.from(rawInput),
    );
  }
}

class SideChatQuestionRequest {
  final String requestId;
  final List<Map<String, dynamic>> questions;

  const SideChatQuestionRequest({
    required this.requestId,
    required this.questions,
  });

  factory SideChatQuestionRequest.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const ['requestId', 'questions']);
    final rawQuestions = json['questions'];
    if (rawQuestions is! List || rawQuestions.isEmpty) {
      throw const FormatException(
        'Side chat question must include at least one question.',
      );
    }
    final questions = requestUserInputQuestions({'questions': rawQuestions});
    if (questions.length != rawQuestions.length) {
      throw const FormatException('Invalid side chat question payload.');
    }
    return SideChatQuestionRequest(
      requestId: _sideChatRequiredString(json, 'requestId'),
      questions: List.unmodifiable(questions),
    );
  }
}

class SideChatErrorPayload {
  final String? code;
  final String message;

  const SideChatErrorPayload({required this.message, this.code});

  factory SideChatErrorPayload.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const ['code', 'message']);
    return SideChatErrorPayload(
      code: _sideChatOptionalString(json, 'code'),
      message: _sideChatRequiredString(json, 'message'),
    );
  }
}

class SideChatEventMessage implements LocalFeatureTransientMessage {
  final SideChatEventKind event;
  final String parentSessionId;
  final String? sideChatId;
  final String? requestId;
  final String? clientMessageId;
  final bool queued;
  final SideChatTranscriptMessage? message;
  final String? status;
  final SideChatPermissionRequest? permission;
  final SideChatQuestionRequest? question;
  final SideChatErrorPayload? error;

  const SideChatEventMessage({
    required this.event,
    required this.parentSessionId,
    this.sideChatId,
    this.requestId,
    this.clientMessageId,
    this.queued = false,
    this.message,
    this.status,
    this.permission,
    this.question,
    this.error,
  });

  @override
  String get featureId => 'side_chat';

  @override
  String get sessionId => parentSessionId;

  factory SideChatEventMessage.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const [
      'type',
      'event',
      'parentSessionId',
      'sideChatId',
      'requestId',
      'clientMessageId',
      'queued',
      'message',
      'status',
      'permission',
      'question',
      'error',
    ]);
    final event = SideChatEventKind.parse(json['event']);
    final parentSessionId = _sideChatRequiredString(json, 'parentSessionId');
    final sideChatId = _sideChatOptionalString(json, 'sideChatId');
    final requestId = _sideChatOptionalString(json, 'requestId');
    final clientMessageId = _sideChatOptionalString(json, 'clientMessageId');
    final rawQueued = json['queued'];
    if (rawQueued != null && rawQueued is! bool) {
      throw const FormatException('Side chat queued flag must be a bool.');
    }
    final queued = rawQueued as bool? ?? false;
    final message = _sideChatOptionalMap(json, 'message');
    final permission = _sideChatOptionalMap(json, 'permission');
    final question = _sideChatOptionalMap(json, 'question');
    final error = _sideChatOptionalMap(json, 'error');
    final status = _sideChatOptionalString(json, 'status');

    void requireSideChatId() {
      if (sideChatId == null) {
        throw FormatException('${event.wireValue} requires sideChatId.');
      }
    }

    switch (event) {
      case SideChatEventKind.opened:
        requireSideChatId();
        if (requestId == null) {
          throw const FormatException('opened requires requestId.');
        }
      case SideChatEventKind.inputAccepted:
        requireSideChatId();
        if (requestId == null || clientMessageId == null) {
          throw const FormatException(
            'input_accepted requires requestId and clientMessageId.',
          );
        }
      case SideChatEventKind.message:
        requireSideChatId();
        if (message == null) {
          throw const FormatException('message requires message payload.');
        }
      case SideChatEventKind.status:
        requireSideChatId();
        if (status == null) {
          throw const FormatException('status requires status payload.');
        }
      case SideChatEventKind.permissionRequest:
        requireSideChatId();
        if (permission == null) {
          throw const FormatException(
            'permission_request requires permission payload.',
          );
        }
      case SideChatEventKind.question:
        requireSideChatId();
        if (question == null) {
          throw const FormatException('question requires question payload.');
        }
      case SideChatEventKind.closed:
        requireSideChatId();
      case SideChatEventKind.error:
        if (error == null) {
          throw const FormatException('error requires error payload.');
        }
    }

    return SideChatEventMessage(
      event: event,
      parentSessionId: parentSessionId,
      sideChatId: sideChatId,
      requestId: requestId,
      clientMessageId: clientMessageId,
      queued: queued,
      message: message == null
          ? null
          : SideChatTranscriptMessage.fromJson(message),
      status: status,
      permission: permission == null
          ? null
          : SideChatPermissionRequest.fromJson(permission),
      question: question == null
          ? null
          : SideChatQuestionRequest.fromJson(question),
      error: error == null ? null : SideChatErrorPayload.fromJson(error),
    );
  }
}

const int sideChatProtocolMaxInputCharacters = 100000;

ClientMessage requestOpenSideChat({
  required String parentSessionId,
  required String requestId,
}) => _sideChatClientMessage(
  type: 'open_side_chat',
  parentSessionId: parentSessionId,
  requestId: requestId,
);

ClientMessage requestSideChatInput({
  required String parentSessionId,
  required String sideChatId,
  required String requestId,
  required String clientMessageId,
  required String text,
}) {
  if (text.trim().isEmpty || text.length > sideChatProtocolMaxInputCharacters) {
    throw ArgumentError.value(text, 'text', 'must be non-empty and bounded');
  }
  return _sideChatClientMessage(
    type: 'side_chat_input',
    parentSessionId: parentSessionId,
    sideChatId: sideChatId,
    requestId: requestId,
    fields: {'clientMessageId': clientMessageId, 'text': text},
  );
}

ClientMessage requestSideChatPermissionResponse({
  required String parentSessionId,
  required String sideChatId,
  required String requestId,
  required String permissionRequestId,
  required SideChatPermissionDecision decision,
}) => _sideChatClientMessage(
  type: 'side_chat_permission_response',
  parentSessionId: parentSessionId,
  sideChatId: sideChatId,
  requestId: requestId,
  fields: {
    'permissionRequestId': _sideChatClientId(
      permissionRequestId,
      'permissionRequestId',
      128,
    ),
    'decision': decision.wireValue,
  },
);

ClientMessage requestSideChatAnswer({
  required String parentSessionId,
  required String sideChatId,
  required String requestId,
  required String questionRequestId,
  required String answer,
}) {
  if (answer.trim().isEmpty ||
      answer.length > sideChatProtocolMaxInputCharacters) {
    throw ArgumentError.value(
      answer,
      'answer',
      'must be non-empty and bounded',
    );
  }
  return _sideChatClientMessage(
    type: 'side_chat_answer',
    parentSessionId: parentSessionId,
    sideChatId: sideChatId,
    requestId: requestId,
    fields: {
      'questionRequestId': _sideChatClientId(
        questionRequestId,
        'questionRequestId',
        128,
      ),
      'answer': answer,
    },
  );
}

ClientMessage requestSideChatInterrupt({
  required String parentSessionId,
  required String sideChatId,
  required String requestId,
}) => _sideChatClientMessage(
  type: 'side_chat_interrupt',
  parentSessionId: parentSessionId,
  sideChatId: sideChatId,
  requestId: requestId,
);

ClientMessage requestCloseSideChat({
  required String parentSessionId,
  required String sideChatId,
  required String requestId,
}) => _sideChatClientMessage(
  type: 'close_side_chat',
  parentSessionId: parentSessionId,
  sideChatId: sideChatId,
  requestId: requestId,
);

ClientMessage _sideChatClientMessage({
  required String type,
  required String parentSessionId,
  required String requestId,
  String? sideChatId,
  Map<String, dynamic> fields = const {},
}) {
  return ClientMessage._({
    'type': type,
    'parentSessionId': _sideChatClientId(
      parentSessionId,
      'parentSessionId',
      256,
    ),
    if (sideChatId != null)
      'sideChatId': _sideChatClientId(sideChatId, 'sideChatId', 256),
    'requestId': _sideChatClientId(requestId, 'requestId', 128),
    ...fields,
  }, delivery: ClientMessageDelivery.ephemeral);
}

String _sideChatClientId(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
  return value;
}

String _sideChatRequiredString(
  Map<String, dynamic> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('Side chat field $key must be a non-empty string.');
  }
  return value;
}

String? _sideChatOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Side chat field $key must be a non-empty string.');
  }
  return value;
}

Map<String, dynamic>? _sideChatOptionalMap(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) {
    throw FormatException('Side chat field $key must be a map.');
  }
  return Map<String, dynamic>.from(value);
}

void _sideChatRequireOnlyKeys(Map<String, dynamic> json, List<String> allowed) {
  final allowedSet = allowed.toSet();
  if (json.keys.any((key) => !allowedSet.contains(key))) {
    throw const FormatException('Side chat message contains unknown fields.');
  }
}
