part of '../../messages.dart';

const LocalFeatureProtocolSlot persistedSideChatProtocolSlot =
    _PersistedSideChatProtocolSlot();

class _PersistedSideChatProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _PersistedSideChatProtocolSlot();

  @override
  String get featureId => 'persisted_side_chat';

  @override
  List<String> get supportedServerMessageTypes => const [
    'persisted_side_chat_opened',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) =>
      json['type'] == 'persisted_side_chat_opened'
      ? PersistedSideChatOpenedMessage.fromJson(json)
      : null;

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    if (request['type'] != 'open_persisted_side_chat') return null;
    final parentSessionId = request['parentSessionId'];
    final requestId = request['requestId'];
    if (parentSessionId is! String || requestId is! String) return null;
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: 'open_persisted_side_chat',
      ownerSessionId: parentSessionId,
      requestId: requestId,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) =>
      response is PersistedSideChatOpenedMessage &&
      response.parentSessionId == request.ownerSessionId &&
      response.requestId == request.requestId;

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) => false;
}

class PersistedSideChatOpenedMessage implements LocalFeatureTransientMessage {
  final String parentSessionId;
  final String requestId;
  final String? childSessionId;
  final String? projectPath;
  final String? worktreePath;
  final String? worktreeBranch;
  final String? permissionMode;
  final String? sandboxMode;
  final String? approvalPolicy;
  final String? approvalsReviewer;
  final String? error;
  final String? errorCode;

  const PersistedSideChatOpenedMessage({
    required this.parentSessionId,
    required this.requestId,
    this.childSessionId,
    this.projectPath,
    this.worktreePath,
    this.worktreeBranch,
    this.permissionMode,
    this.sandboxMode,
    this.approvalPolicy,
    this.approvalsReviewer,
    this.error,
    this.errorCode,
  });

  @override
  String get featureId => 'persisted_side_chat';

  @override
  String get sessionId => parentSessionId;

  bool get isSuccess => childSessionId != null && error == null;

  factory PersistedSideChatOpenedMessage.fromJson(Map<String, dynamic> json) {
    _sideChatRequireOnlyKeys(json, const [
      'type',
      'parentSessionId',
      'requestId',
      'childSessionId',
      'projectPath',
      'worktreePath',
      'worktreeBranch',
      'permissionMode',
      'sandboxMode',
      'approvalPolicy',
      'approvalsReviewer',
      'error',
      'errorCode',
    ]);
    final childSessionId = _sideChatOptionalString(json, 'childSessionId');
    final error = _sideChatOptionalString(json, 'error');
    if ((childSessionId == null) == (error == null)) {
      throw const FormatException(
        'Durable side chat response must contain exactly one result.',
      );
    }
    return PersistedSideChatOpenedMessage(
      parentSessionId: _sideChatRequiredString(json, 'parentSessionId'),
      requestId: _sideChatRequiredString(json, 'requestId'),
      childSessionId: childSessionId,
      projectPath: _sideChatOptionalString(json, 'projectPath'),
      worktreePath: _sideChatOptionalString(json, 'worktreePath'),
      worktreeBranch: _sideChatOptionalString(json, 'worktreeBranch'),
      permissionMode: _sideChatOptionalString(json, 'permissionMode'),
      sandboxMode: _sideChatOptionalString(json, 'sandboxMode'),
      approvalPolicy: _sideChatOptionalString(json, 'approvalPolicy'),
      approvalsReviewer: _sideChatOptionalString(json, 'approvalsReviewer'),
      error: error,
      errorCode: _sideChatOptionalString(json, 'errorCode'),
    );
  }
}

ClientMessage requestOpenPersistedSideChat({
  required String parentSessionId,
  required String requestId,
}) => ClientMessage._(<String, dynamic>{
  'type': 'open_persisted_side_chat',
  'parentSessionId': _sideChatClientId(parentSessionId, 'parentSessionId', 256),
  'requestId': _sideChatClientId(requestId, 'requestId', 128),
}, delivery: ClientMessageDelivery.ephemeral);
