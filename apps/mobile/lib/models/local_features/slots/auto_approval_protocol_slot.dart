part of '../../messages.dart';

const autoApprovalStateCapability = 'auto_approval_state_v1';

const LocalFeatureProtocolSlot autoApprovalProtocolSlot =
    _AutoApprovalProtocolSlot();

class _AutoApprovalProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _AutoApprovalProtocolSlot();

  @override
  String get featureId => 'auto_approval';

  @override
  List<String> get supportedServerMessageTypes => const [
    autoApprovalStateCapability,
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) =>
      json['type'] == autoApprovalStateCapability
      ? AutoApprovalStateMessage.fromJson(json)
      : null;

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (!const {
      'get_auto_approval_state',
      'set_auto_approval',
      'disable_all_auto_approvals',
      'import_legacy_auto_approvals',
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
  ) =>
      response is AutoApprovalStateMessage &&
      response.sessionId == request.ownerSessionId &&
      response.requestId == request.requestId;

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) =>
      error.errorCode == 'unsupported_capability' &&
      error.message == 'Bridge-owned auto approval was not negotiated';
}

class AutoApprovalStateMessage implements LocalFeatureTransientMessage {
  @override
  final String sessionId;
  final String? requestId;
  final String? providerSessionId;
  final bool? enabled;
  final int enabledConversationCount;
  final int? approvedCount;
  final String reason;
  final String? error;
  final String? errorCode;

  const AutoApprovalStateMessage({
    required this.sessionId,
    required this.enabledConversationCount,
    required this.reason,
    this.requestId,
    this.providerSessionId,
    this.enabled,
    this.approvedCount,
    this.error,
    this.errorCode,
  });

  @override
  String get featureId => 'auto_approval';

  bool get isSuccess => error == null;

  factory AutoApprovalStateMessage.fromJson(Map<String, dynamic> json) {
    const allowedKeys = {
      'type',
      'sessionId',
      'requestId',
      'providerSessionId',
      'enabled',
      'enabledConversationCount',
      'approvedCount',
      'reason',
      'error',
      'errorCode',
    };
    if (json.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('Unexpected auto-approval state field.');
    }
    final sessionId = _autoApprovalRequiredString(json, 'sessionId', 256);
    final requestId = _autoApprovalOptionalString(json, 'requestId', 128);
    final providerSessionId = _autoApprovalOptionalString(
      json,
      'providerSessionId',
      256,
    );
    final enabled = json['enabled'];
    final enabledConversationCount = json['enabledConversationCount'];
    final approvedCount = json['approvedCount'];
    final reason = _autoApprovalRequiredString(json, 'reason', 32);
    final error = _autoApprovalOptionalString(json, 'error', 1024);
    final errorCode = _autoApprovalOptionalString(json, 'errorCode', 128);
    if ((enabled != null && enabled is! bool) ||
        enabledConversationCount is! int ||
        enabledConversationCount < 0 ||
        enabledConversationCount > 4096 ||
        (approvedCount != null &&
            (approvedCount is! int || approvedCount < 0)) ||
        !const {
          'query',
          'updated',
          'disabled_all',
          'legacy_imported',
          'auto_approved',
        }.contains(reason) ||
        ((error == null) != (errorCode == null))) {
      throw const FormatException('Invalid auto-approval state payload.');
    }
    return AutoApprovalStateMessage(
      sessionId: sessionId,
      requestId: requestId,
      providerSessionId: providerSessionId,
      enabled: enabled as bool?,
      enabledConversationCount: enabledConversationCount,
      approvedCount: approvedCount as int?,
      reason: reason,
      error: error,
      errorCode: errorCode,
    );
  }
}

ClientMessage requestAutoApprovalState({
  required String sessionId,
  required String requestId,
}) => LocalFeatureProtocolHost.ephemeralRequest(
  type: 'get_auto_approval_state',
  sessionId: _autoApprovalClientId(sessionId, 'sessionId', 256),
  requestId: _autoApprovalClientId(requestId, 'requestId', 128),
);

ClientMessage requestSetAutoApproval({
  required String sessionId,
  required String requestId,
  required bool enabled,
}) => LocalFeatureProtocolHost.ephemeralRequest(
  type: 'set_auto_approval',
  sessionId: _autoApprovalClientId(sessionId, 'sessionId', 256),
  requestId: _autoApprovalClientId(requestId, 'requestId', 128),
  fields: {'enabled': enabled},
);

ClientMessage requestDisableAllAutoApprovals({
  required String sessionId,
  required String requestId,
}) => LocalFeatureProtocolHost.ephemeralRequest(
  type: 'disable_all_auto_approvals',
  sessionId: _autoApprovalClientId(sessionId, 'sessionId', 256),
  requestId: _autoApprovalClientId(requestId, 'requestId', 128),
);

ClientMessage requestImportLegacyAutoApprovals({
  required String sessionId,
  required String requestId,
  required List<String> providerSessionIds,
}) {
  if (providerSessionIds.length > 512) {
    throw ArgumentError.value(
      providerSessionIds.length,
      'providerSessionIds',
      'must contain no more than 512 IDs',
    );
  }
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'import_legacy_auto_approvals',
    sessionId: _autoApprovalClientId(sessionId, 'sessionId', 256),
    requestId: _autoApprovalClientId(requestId, 'requestId', 128),
    fields: {
      'providerSessionIds': providerSessionIds
          .map((id) => _autoApprovalClientId(id, 'providerSessionId', 256))
          .toSet()
          .toList(),
    },
  );
}

String _autoApprovalRequiredString(
  Map<String, dynamic> json,
  String key,
  int maxLength,
) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('Auto-approval state requires $key.');
  }
  return value;
}

String? _autoApprovalOptionalString(
  Map<String, dynamic> json,
  String key,
  int maxLength,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('Invalid auto-approval $key.');
  }
  return value;
}

String _autoApprovalClientId(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
  return value;
}
