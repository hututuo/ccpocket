part of '../../messages.dart';

const LocalFeatureProtocolSlot codexCoreActionsProtocolSlot =
    _CodexCoreActionsProtocolSlot();

class _CodexCoreActionsProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _CodexCoreActionsProtocolSlot();

  @override
  String get featureId => 'codex_core_actions';

  @override
  List<String> get supportedServerMessageTypes => const [
    'codex_action_result',
    'codex_mcp_status_result',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => switch (json['type']) {
    'codex_action_result' => CodexActionResultMessage.fromJson(json),
    'codex_mcp_status_result' => CodexMcpStatusResultMessage.fromJson(json),
    _ => null,
  };

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (type != 'codex_compact_request' &&
        type != 'codex_review_request' &&
        type != 'codex_mcp_status_request') {
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
    if (request.requestType == 'codex_mcp_status_request') {
      return response is CodexMcpStatusResultMessage &&
          response.sessionId == request.ownerSessionId &&
          response.requestId == request.requestId;
    }
    if (response is! CodexActionResultMessage ||
        response.sessionId != request.ownerSessionId ||
        response.requestId != request.requestId) {
      return false;
    }
    return switch (request.requestType) {
      'codex_compact_request' => response.action == 'compact',
      'codex_review_request' => response.action == 'review',
      _ => false,
    };
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) => false;
}

sealed class CodexReviewTarget {
  const CodexReviewTarget();

  Map<String, dynamic> toJson();
}

class CodexReviewUncommittedTarget extends CodexReviewTarget {
  const CodexReviewUncommittedTarget();

  @override
  Map<String, dynamic> toJson() => const {'type': 'uncommittedChanges'};
}

class CodexReviewBaseBranchTarget extends CodexReviewTarget {
  final String branch;

  const CodexReviewBaseBranchTarget(this.branch);

  @override
  Map<String, dynamic> toJson() {
    _requireCodexCoreActionText(branch, 'branch', 512);
    return {'type': 'baseBranch', 'branch': branch.trim()};
  }
}

class CodexReviewCommitTarget extends CodexReviewTarget {
  final String sha;
  final String? title;

  const CodexReviewCommitTarget(this.sha, {this.title});

  @override
  Map<String, dynamic> toJson() {
    _requireCodexCoreActionText(sha, 'sha', 128);
    final normalizedTitle = title?.trim();
    if (normalizedTitle != null && normalizedTitle.length > 512) {
      throw ArgumentError.value(title, 'title', 'must be bounded');
    }
    return {
      'type': 'commit',
      'sha': sha.trim(),
      'title': normalizedTitle?.isEmpty == true ? null : normalizedTitle,
    };
  }
}

class CodexReviewCustomTarget extends CodexReviewTarget {
  final String instructions;

  const CodexReviewCustomTarget(this.instructions);

  @override
  Map<String, dynamic> toJson() {
    _requireCodexCoreActionText(instructions, 'instructions', 8000);
    return {'type': 'custom', 'instructions': instructions.trim()};
  }
}

ClientMessage requestCodexCompact({
  required String sessionId,
  required String requestId,
}) {
  _requireCodexCoreActionId(sessionId, 'sessionId', 256);
  _requireCodexCoreActionId(requestId, 'requestId', 128);
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'codex_compact_request',
    sessionId: sessionId,
    requestId: requestId,
  );
}

ClientMessage requestCodexReview({
  required String sessionId,
  required String requestId,
  required CodexReviewTarget target,
}) {
  _requireCodexCoreActionId(sessionId, 'sessionId', 256);
  _requireCodexCoreActionId(requestId, 'requestId', 128);
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'codex_review_request',
    sessionId: sessionId,
    requestId: requestId,
    fields: {'target': target.toJson()},
  );
}

ClientMessage requestCodexMcpStatus({
  required String sessionId,
  required String requestId,
}) {
  _requireCodexCoreActionId(sessionId, 'sessionId', 256);
  _requireCodexCoreActionId(requestId, 'requestId', 128);
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'codex_mcp_status_request',
    sessionId: sessionId,
    requestId: requestId,
  );
}

class CodexActionResultMessage implements LocalFeatureTransientMessage {
  @override
  final String sessionId;
  final String requestId;
  final String action;
  final String status;
  final String? turnId;
  final String? reviewThreadId;
  final String? errorCode;
  final String? message;

  const CodexActionResultMessage({
    required this.sessionId,
    required this.requestId,
    required this.action,
    required this.status,
    this.turnId,
    this.reviewThreadId,
    this.errorCode,
    this.message,
  });

  @override
  String get featureId => 'codex_core_actions';

  bool get accepted => status == 'accepted';

  factory CodexActionResultMessage.fromJson(Map<String, dynamic> json) {
    final sessionId = _codexCoreActionString(json['sessionId'], 256);
    final requestId = _codexCoreActionString(json['requestId'], 128);
    final action = _codexCoreActionString(json['action'], 32);
    final status = _codexCoreActionString(json['status'], 32);
    if (sessionId == null ||
        requestId == null ||
        (action != 'compact' && action != 'review') ||
        !const {
          'accepted',
          'unsupported',
          'rejected',
          'failed',
        }.contains(status)) {
      throw const FormatException('Invalid codex_action_result');
    }
    return CodexActionResultMessage(
      sessionId: sessionId,
      requestId: requestId,
      action: action!,
      status: status!,
      turnId: _codexCoreActionString(json['turnId'], 256),
      reviewThreadId: _codexCoreActionString(json['reviewThreadId'], 256),
      errorCode: _codexCoreActionString(json['errorCode'], 128),
      message: _codexCoreActionString(json['message'], 2000),
    );
  }
}

class CodexMcpToolStatus {
  final String name;
  final String? title;
  final String? description;

  const CodexMcpToolStatus({required this.name, this.title, this.description});

  factory CodexMcpToolStatus.fromJson(Map<String, dynamic> json) {
    final name = _codexCoreActionString(json['name'], 256);
    if (name == null) {
      throw const FormatException('MCP tool requires a name');
    }
    return CodexMcpToolStatus(
      name: name,
      title: _codexCoreActionString(json['title'], 512),
      description: _codexCoreActionString(json['description'], 2000),
    );
  }
}

class CodexMcpServerInfo {
  final String name;
  final String? title;
  final String? version;
  final String? description;
  final String? websiteUrl;

  const CodexMcpServerInfo({
    required this.name,
    this.title,
    this.version,
    this.description,
    this.websiteUrl,
  });

  factory CodexMcpServerInfo.fromJson(Map<String, dynamic> json) {
    final name = _codexCoreActionString(json['name'], 256);
    if (name == null) {
      throw const FormatException('MCP server info requires a name');
    }
    return CodexMcpServerInfo(
      name: name,
      title: _codexCoreActionString(json['title'], 512),
      version: _codexCoreActionString(json['version'], 128),
      description: _codexCoreActionString(json['description'], 2000),
      websiteUrl: _codexCoreActionString(json['websiteUrl'], 2000),
    );
  }
}

class CodexMcpServerStatus {
  final String name;
  final String authStatus;
  final CodexMcpServerInfo? serverInfo;
  final List<CodexMcpToolStatus> tools;
  final int toolCount;
  final bool toolsTruncated;

  const CodexMcpServerStatus({
    required this.name,
    required this.authStatus,
    this.serverInfo,
    required this.tools,
    required this.toolCount,
    required this.toolsTruncated,
  });

  factory CodexMcpServerStatus.fromJson(Map<String, dynamic> json) {
    final name = _codexCoreActionString(json['name'], 256);
    final authStatus = _codexCoreActionString(json['authStatus'], 128);
    if (name == null || authStatus == null) {
      throw const FormatException('Invalid MCP server status');
    }
    final rawTools = json['tools'];
    final tools = <CodexMcpToolStatus>[];
    if (rawTools is List) {
      for (final raw in rawTools.take(128)) {
        if (raw is Map) {
          tools.add(
            CodexMcpToolStatus.fromJson(Map<String, dynamic>.from(raw)),
          );
        }
      }
    }
    final rawInfo = json['serverInfo'];
    return CodexMcpServerStatus(
      name: name,
      authStatus: authStatus,
      serverInfo: rawInfo is Map
          ? CodexMcpServerInfo.fromJson(Map<String, dynamic>.from(rawInfo))
          : null,
      tools: List.unmodifiable(tools),
      toolCount: _codexCoreActionInt(json['toolCount']) ?? tools.length,
      toolsTruncated: json['toolsTruncated'] == true,
    );
  }
}

class CodexMcpStatusResultMessage implements LocalFeatureTransientMessage {
  @override
  final String sessionId;
  final String requestId;
  final String status;
  final List<CodexMcpServerStatus> servers;
  final bool serversTruncated;
  final String? errorCode;
  final String? message;

  const CodexMcpStatusResultMessage({
    required this.sessionId,
    required this.requestId,
    required this.status,
    required this.servers,
    required this.serversTruncated,
    this.errorCode,
    this.message,
  });

  @override
  String get featureId => 'codex_core_actions';

  factory CodexMcpStatusResultMessage.fromJson(Map<String, dynamic> json) {
    final sessionId = _codexCoreActionString(json['sessionId'], 256);
    final requestId = _codexCoreActionString(json['requestId'], 128);
    final status = _codexCoreActionString(json['status'], 32);
    if (sessionId == null ||
        requestId == null ||
        !const {'completed', 'unsupported', 'failed'}.contains(status)) {
      throw const FormatException('Invalid codex_mcp_status_result');
    }
    final servers = <CodexMcpServerStatus>[];
    final rawServers = json['servers'];
    if (rawServers is List) {
      for (final raw in rawServers.take(64)) {
        if (raw is Map) {
          servers.add(
            CodexMcpServerStatus.fromJson(Map<String, dynamic>.from(raw)),
          );
        }
      }
    }
    return CodexMcpStatusResultMessage(
      sessionId: sessionId,
      requestId: requestId,
      status: status!,
      servers: List.unmodifiable(servers),
      serversTruncated: json['serversTruncated'] == true,
      errorCode: _codexCoreActionString(json['errorCode'], 128),
      message: _codexCoreActionString(json['message'], 2000),
    );
  }
}

void _requireCodexCoreActionId(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
}

void _requireCodexCoreActionText(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
}

String? _codexCoreActionString(Object? value, int maxLength) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) return null;
  return normalized;
}

int? _codexCoreActionInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0 && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}
