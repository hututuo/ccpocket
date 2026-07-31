part of '../../messages.dart';

const codexActionBrokerBridgeCapability = 'codex_action_broker_v1';

const LocalFeatureProtocolSlot codexActionBrokerProtocolSlot =
    _CodexActionBrokerProtocolSlot();

class _CodexActionBrokerProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _CodexActionBrokerProtocolSlot();

  @override
  String get featureId => 'codex_action_broker';

  @override
  List<String> get supportedServerMessageTypes => const [
    codexActionBrokerBridgeCapability,
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) {
    if (json['type'] != codexActionBrokerBridgeCapability) return null;
    return CodexActionBrokerEventMessage.fromJson(json);
  }

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    if (request['type'] != 'respond_codex_action') return null;
    final threadId = request['threadId'];
    final requestId = request['requestId'];
    if (threadId is! String || requestId is! String) return null;
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: 'respond_codex_action',
      ownerSessionId: threadId,
      requestId: requestId,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) =>
      response is CodexActionBrokerEventMessage &&
      response.event == CodexActionBrokerEventKind.response &&
      response.requestId == request.requestId;

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) =>
      error.errorCode == 'unsupported_capability' &&
      error.message.toLowerCase().contains('codex action broker');
}

enum CodexActionBrokerEventKind {
  snapshot('snapshot'),
  request('request'),
  health('health'),
  response('response'),
  unknown('__unknown__');

  const CodexActionBrokerEventKind(this.wireValue);

  final String wireValue;

  static CodexActionBrokerEventKind parse(Object? value) {
    for (final event in values) {
      if (event.wireValue == value) return event;
    }
    return unknown;
  }
}

enum CodexActionBrokerRequestKind {
  commandApproval('command_approval'),
  fileApproval('file_approval'),
  permissionsApproval('permissions_approval'),
  userInput('user_input'),
  mcpElicitation('mcp_elicitation'),
  toolSuggestion('tool_suggestion'),
  currentTime('current_time'),
  unknown('unknown');

  const CodexActionBrokerRequestKind(this.wireValue);

  final String wireValue;

  static CodexActionBrokerRequestKind parse(Object? value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    return unknown;
  }
}

enum CodexActionBrokerRequestState {
  pending('pending'),
  claimed('claimed'),
  resolved('resolved'),
  expired('expired');

  const CodexActionBrokerRequestState(this.wireValue);

  final String wireValue;

  static CodexActionBrokerRequestState? tryParse(Object? value) {
    for (final state in values) {
      if (state.wireValue == value) return state;
    }
    return null;
  }
}

enum CodexActionBrokerDecision {
  approve('approve'),
  approveAlways('approve_always'),
  reject('reject'),
  answer('answer');

  const CodexActionBrokerDecision(this.wireValue);

  final String wireValue;

  static CodexActionBrokerDecision? tryParse(Object? value) {
    for (final decision in values) {
      if (decision.wireValue == value) return decision;
    }
    return null;
  }
}

enum CodexActionBrokerResponseOutcome {
  submitted('submitted'),
  outcomeUnknown('outcomeUnknown'),
  alreadyResolved('alreadyResolved'),
  contended('contended'),
  expired('expired'),
  staleGeneration('staleGeneration'),
  unavailable('unavailable'),
  invalid('invalid');

  const CodexActionBrokerResponseOutcome(this.wireValue);

  final String wireValue;

  static CodexActionBrokerResponseOutcome? tryParse(Object? value) {
    for (final outcome in values) {
      if (outcome.wireValue == value) return outcome;
    }
    return null;
  }
}

class CodexActionBrokerHealth {
  const CodexActionBrokerHealth({
    required this.ready,
    required this.controlReady,
    required this.degraded,
    required this.writerLeaseHeld,
    this.degradedReason,
    this.authorityGeneration,
  });

  final bool ready;
  final bool controlReady;
  final bool degraded;
  final bool writerLeaseHeld;
  final String? degradedReason;
  final String? authorityGeneration;

  factory CodexActionBrokerHealth.fromJson(Map<String, dynamic> json) {
    final ready = json['ready'];
    final controlReady = json['controlReady'];
    final degraded = json['degraded'];
    final writerLeaseHeld = json['writerLeaseHeld'];
    if (ready is! bool ||
        controlReady is! bool ||
        degraded is! bool ||
        writerLeaseHeld is! bool) {
      throw const FormatException('Invalid Codex action broker health.');
    }
    final degradedReason = _codexActionBrokerOptionalString(
      json['degradedReason'],
      64,
    );
    if (degradedReason != null &&
        !const {
          'unreadable_state',
          'unsafe_state',
          'generation_unavailable',
          'writer_lease_unavailable',
          'unsupported_server_request',
          'unsupported_topology',
        }.contains(degradedReason)) {
      throw const FormatException(
        'Invalid Codex action broker degraded reason.',
      );
    }
    final authorityGeneration = _codexActionBrokerOptionalString(
      json['authorityGeneration'],
      64,
    );
    if (ready &&
        (!controlReady ||
            degraded ||
            !writerLeaseHeld ||
            authorityGeneration == null)) {
      throw const FormatException(
        'Ready Codex action broker health is internally inconsistent.',
      );
    }
    return CodexActionBrokerHealth(
      ready: ready,
      controlReady: controlReady,
      degraded: degraded,
      writerLeaseHeld: writerLeaseHeld,
      degradedReason: degradedReason,
      authorityGeneration: authorityGeneration,
    );
  }
}

class CodexActionBrokerRequest {
  const CodexActionBrokerRequest({
    required this.opaqueRequestId,
    required this.codexSourceId,
    required this.threadId,
    required this.turnId,
    required this.kind,
    required this.state,
    required this.observedAt,
    required this.expiresAt,
    required this.updatedAt,
    required this.authorityGeneration,
    required this.live,
    this.toolName,
    this.input = const {},
    this.allowedActions = const {},
  });

  final String opaqueRequestId;
  final String codexSourceId;
  final String threadId;
  final String turnId;
  final CodexActionBrokerRequestKind kind;
  final CodexActionBrokerRequestState state;
  final DateTime observedAt;
  final DateTime expiresAt;
  final DateTime updatedAt;
  final String authorityGeneration;
  final bool live;
  final String? toolName;
  final Map<String, dynamic> input;
  final Set<CodexActionBrokerDecision> allowedActions;

  bool get terminal =>
      state == CodexActionBrokerRequestState.resolved ||
      state == CodexActionBrokerRequestState.expired;

  factory CodexActionBrokerRequest.fromJson(Map<String, dynamic> json) =>
      _fromJson(json, _CodexActionBrokerInputBudget());

  static CodexActionBrokerRequest _fromJson(
    Map<String, dynamic> json,
    _CodexActionBrokerInputBudget inputBudget,
  ) {
    final state = CodexActionBrokerRequestState.tryParse(json['state']);
    final rawLive = json['live'];
    final rawInput = json['input'];
    final rawActions = json['allowedActions'];
    if (state == null ||
        rawLive is! bool ||
        (rawInput != null && rawInput is! Map) ||
        (rawActions != null && rawActions is! List)) {
      throw const FormatException('Invalid Codex action broker request.');
    }
    final allowedActions = <CodexActionBrokerDecision>{};
    if (rawActions is List) {
      if (rawActions.length > CodexActionBrokerDecision.values.length) {
        throw const FormatException(
          'Codex action broker allowedActions is too large.',
        );
      }
      for (final rawAction in rawActions) {
        final action = CodexActionBrokerDecision.tryParse(rawAction);
        if (action != null) allowedActions.add(action);
      }
    }
    return CodexActionBrokerRequest(
      opaqueRequestId: _codexActionBrokerRequiredString(
        json['opaqueRequestId'],
        256,
        'opaqueRequestId',
      ),
      codexSourceId: _codexActionBrokerRequiredString(
        json['codexSourceId'],
        128,
        'codexSourceId',
      ),
      threadId: _codexActionBrokerRequiredString(
        json['threadId'],
        256,
        'threadId',
      ),
      turnId: _codexActionBrokerRequiredString(json['turnId'], 256, 'turnId'),
      kind: CodexActionBrokerRequestKind.parse(json['kind']),
      state: state,
      observedAt: _codexActionBrokerDate(json['observedAt'], 'observedAt'),
      expiresAt: _codexActionBrokerDate(json['expiresAt'], 'expiresAt'),
      updatedAt: _codexActionBrokerDate(json['updatedAt'], 'updatedAt'),
      authorityGeneration: _codexActionBrokerRequiredString(
        json['authorityGeneration'],
        64,
        'authorityGeneration',
      ),
      live: rawLive,
      toolName: _codexActionBrokerOptionalString(json['toolName'], 256),
      input: rawInput == null
          ? const {}
          : Map<String, dynamic>.unmodifiable(
              _boundedCodexActionBrokerInput(rawInput, inputBudget),
            ),
      allowedActions: Set.unmodifiable(allowedActions),
    );
  }
}

class CodexActionBrokerEventMessage implements LocalFeatureTransientMessage {
  const CodexActionBrokerEventMessage({
    required this.event,
    this.requestId,
    this.health,
    this.requests = const [],
    this.request,
    this.outcome,
    this.opaqueRequestId,
    this.error,
    this.scope,
    this.truncated = false,
  });

  @override
  String get featureId => 'codex_action_broker';

  final CodexActionBrokerEventKind event;
  final String? requestId;
  final CodexActionBrokerHealth? health;
  final List<CodexActionBrokerRequest> requests;
  final CodexActionBrokerRequest? request;
  final CodexActionBrokerResponseOutcome? outcome;
  final String? opaqueRequestId;
  final String? error;
  final CodexActionBrokerSnapshotScope? scope;
  final bool truncated;

  @override
  String? get sessionId => switch (event) {
    CodexActionBrokerEventKind.request => request?.threadId,
    CodexActionBrokerEventKind.response => request?.threadId,
    _ => null,
  };

  factory CodexActionBrokerEventMessage.fromJson(Map<String, dynamic> json) {
    final event = CodexActionBrokerEventKind.parse(json['event']);
    if (event == CodexActionBrokerEventKind.unknown) {
      return const CodexActionBrokerEventMessage(
        event: CodexActionBrokerEventKind.unknown,
      );
    }
    switch (event) {
      case CodexActionBrokerEventKind.snapshot:
        final rawHealth = json['health'];
        final rawRequests = json['requests'];
        final rawScope = json['scope'];
        final rawTruncated = json['truncated'];
        if (rawHealth is! Map ||
            rawRequests is! List ||
            rawRequests.length > 1024 ||
            (rawScope != null && rawScope is! Map) ||
            (rawTruncated != null && rawTruncated is! bool)) {
          throw const FormatException('Invalid Codex action broker snapshot.');
        }
        final inputBudget = _CodexActionBrokerInputBudget(
          maximumNodes: 16 * 1024,
          maximumStringCodeUnits: 1024 * 1024,
        );
        return CodexActionBrokerEventMessage(
          event: event,
          requestId: _codexActionBrokerOptionalString(json['requestId'], 128),
          health: CodexActionBrokerHealth.fromJson(
            Map<String, dynamic>.from(rawHealth),
          ),
          scope: rawScope == null
              ? null
              : CodexActionBrokerSnapshotScope.fromJson(
                  Map<String, dynamic>.from(rawScope),
                ),
          truncated: rawTruncated == true,
          requests: List<CodexActionBrokerRequest>.unmodifiable(
            rawRequests.map((raw) {
              if (raw is! Map) {
                throw const FormatException(
                  'Invalid Codex action broker snapshot request.',
                );
              }
              return CodexActionBrokerRequest._fromJson(
                Map<String, dynamic>.from(raw),
                inputBudget,
              );
            }),
          ),
        );
      case CodexActionBrokerEventKind.request:
        final rawRequest = json['request'];
        if (rawRequest is! Map) {
          throw const FormatException('Invalid Codex action broker update.');
        }
        return CodexActionBrokerEventMessage(
          event: event,
          request: CodexActionBrokerRequest.fromJson(
            Map<String, dynamic>.from(rawRequest),
          ),
        );
      case CodexActionBrokerEventKind.health:
        final rawHealth = json['health'];
        if (rawHealth is! Map) {
          throw const FormatException('Invalid Codex action broker health.');
        }
        return CodexActionBrokerEventMessage(
          event: event,
          health: CodexActionBrokerHealth.fromJson(
            Map<String, dynamic>.from(rawHealth),
          ),
        );
      case CodexActionBrokerEventKind.response:
        final outcome = CodexActionBrokerResponseOutcome.tryParse(
          json['outcome'],
        );
        final rawRequest = json['request'];
        if (outcome == null || (rawRequest != null && rawRequest is! Map)) {
          throw const FormatException('Invalid Codex action broker response.');
        }
        return CodexActionBrokerEventMessage(
          event: event,
          requestId: _codexActionBrokerRequiredString(
            json['requestId'],
            128,
            'requestId',
          ),
          opaqueRequestId: _codexActionBrokerRequiredString(
            json['opaqueRequestId'],
            256,
            'opaqueRequestId',
          ),
          outcome: outcome,
          request: rawRequest == null
              ? null
              : CodexActionBrokerRequest.fromJson(
                  Map<String, dynamic>.from(rawRequest),
                ),
          error: _codexActionBrokerOptionalString(json['error'], 2000),
        );
      case CodexActionBrokerEventKind.unknown:
        throw StateError('Handled above.');
    }
  }
}

class CodexActionBrokerSnapshotScope {
  const CodexActionBrokerSnapshotScope({
    required this.codexSourceId,
    required this.threadId,
  });

  final String codexSourceId;
  final String threadId;

  factory CodexActionBrokerSnapshotScope.fromJson(Map<String, dynamic> json) =>
      CodexActionBrokerSnapshotScope(
        codexSourceId: _codexActionBrokerRequiredString(
          json['codexSourceId'],
          128,
          'scope.codexSourceId',
        ),
        threadId: _codexActionBrokerRequiredString(
          json['threadId'],
          256,
          'scope.threadId',
        ),
      );
}

ClientMessage requestCodexActions({
  required String requestId,
  required String codexSourceId,
  required String threadId,
}) {
  final normalizedRequestId = _codexActionBrokerCheckedId(
    requestId,
    'requestId',
    128,
  );
  return ClientMessage._(<String, dynamic>{
    'type': 'get_codex_actions',
    'requestId': normalizedRequestId,
    'codexSourceId': _codexActionBrokerCheckedId(
      codexSourceId,
      'codexSourceId',
      128,
    ),
    'threadId': _codexActionBrokerCheckedId(threadId, 'threadId', 256),
  }, delivery: ClientMessageDelivery.ephemeral);
}

ClientMessage respondCodexAction({
  required String requestId,
  required CodexActionBrokerRequest request,
  required String claimantId,
  required String operationId,
  required CodexActionBrokerDecision action,
  String? answer,
}) {
  final normalizedRequestId = _codexActionBrokerCheckedId(
    requestId,
    'requestId',
    128,
  );
  final normalizedClaimantId = _codexActionBrokerCheckedId(
    claimantId,
    'claimantId',
    256,
  );
  final normalizedOperationId = _codexActionBrokerCheckedId(
    operationId,
    'operationId',
    256,
  );
  if (!request.allowedActions.contains(action)) {
    throw ArgumentError.value(action, 'action', 'is not allowed');
  }
  if (action == CodexActionBrokerDecision.answer) {
    if (answer == null || answer.length > 64 * 1024) {
      throw ArgumentError.value(
        answer,
        'answer',
        'must be present and bounded',
      );
    }
  } else if (answer != null) {
    throw ArgumentError.value(answer, 'answer', 'is only valid for answer');
  }
  return ClientMessage._(<String, dynamic>{
    'type': 'respond_codex_action',
    'requestId': normalizedRequestId,
    'opaqueRequestId': request.opaqueRequestId,
    'codexSourceId': request.codexSourceId,
    'threadId': request.threadId,
    'turnId': request.turnId,
    'authorityGeneration': request.authorityGeneration,
    'claimantId': normalizedClaimantId,
    'operationId': normalizedOperationId,
    'action': action.wireValue,
    if (action == CodexActionBrokerDecision.answer) 'answer': answer,
  }, delivery: ClientMessageDelivery.ephemeral);
}

String _codexActionBrokerCheckedId(
  String value,
  String name,
  int maximumLength,
) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maximumLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
  return normalized;
}

String _codexActionBrokerRequiredString(
  Object? value,
  int maximumLength,
  String name,
) {
  if (value is! String ||
      value.trim().isEmpty ||
      value != value.trim() ||
      value.length > maximumLength) {
    throw FormatException('Codex action broker $name is invalid.');
  }
  return value;
}

String? _codexActionBrokerOptionalString(Object? value, int maximumLength) {
  if (value == null) return null;
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maximumLength) {
    throw const FormatException(
      'Codex action broker optional string is invalid.',
    );
  }
  return value;
}

DateTime _codexActionBrokerDate(Object? value, String name) {
  final raw = _codexActionBrokerRequiredString(value, 64, name);
  final parsed = DateTime.tryParse(raw)?.toUtc();
  if (parsed == null) {
    throw FormatException('Codex action broker $name is not an ISO date.');
  }
  return parsed;
}

class _CodexActionBrokerInputBudget {
  _CodexActionBrokerInputBudget({
    this.maximumNodes = 4096,
    this.maximumStringCodeUnits = 128 * 1024,
  });

  final int maximumNodes;
  final int maximumStringCodeUnits;
  int nodes = 0;
  int stringCodeUnits = 0;
}

Map<String, dynamic> _boundedCodexActionBrokerInput(
  Map<dynamic, dynamic> raw,
  _CodexActionBrokerInputBudget budget,
) {
  final decoded = _boundedCodexActionBrokerValue(raw, budget, 0);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Codex action broker input must be a map.');
  }
  return decoded;
}

Object? _boundedCodexActionBrokerValue(
  Object? value,
  _CodexActionBrokerInputBudget budget,
  int depth,
) {
  if (depth > 12 || ++budget.nodes > budget.maximumNodes) {
    throw const FormatException('Codex action broker input is too complex.');
  }
  if (value == null || value is bool || value is num) return value;
  if (value is String) {
    if (value.length > 64 * 1024 ||
        (budget.stringCodeUnits += value.length) >
            budget.maximumStringCodeUnits) {
      throw const FormatException('Codex action broker input is too large.');
    }
    return value;
  }
  if (value is List) {
    if (value.length > 2048) {
      throw const FormatException('Codex action broker list is too large.');
    }
    return List<Object?>.unmodifiable(
      value.map(
        (entry) => _boundedCodexActionBrokerValue(entry, budget, depth + 1),
      ),
    );
  }
  if (value is Map) {
    if (value.length > 2048) {
      throw const FormatException('Codex action broker map is too large.');
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || key.isEmpty || key.length > 256) {
        throw const FormatException(
          'Codex action broker input key is invalid.',
        );
      }
      budget.stringCodeUnits += key.length;
      if (budget.stringCodeUnits > budget.maximumStringCodeUnits) {
        throw const FormatException('Codex action broker input is too large.');
      }
      result[key] = _boundedCodexActionBrokerValue(
        entry.value,
        budget,
        depth + 1,
      );
    }
    return Map<String, dynamic>.unmodifiable(result);
  }
  throw const FormatException('Codex action broker input is not JSON-safe.');
}
