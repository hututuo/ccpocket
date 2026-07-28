part of '../../messages.dart';

/// Read-only metadata for a Codex child-agent thread.
///
/// The model is neutral protocol data so the subagent browser remains an
/// independently removable feature without reversing core dependencies.
class SubagentInfo {
  final String threadId;
  final String? nickname;
  final String? role;
  final String? path;
  final String status;
  final String? model;
  final String? reasoningEffort;
  final String? preview;
  final String? result;
  final String? error;
  final String? startedAt;
  final String? updatedAt;
  final String? completedAt;
  final List<String> activeFlags;

  const SubagentInfo({
    required this.threadId,
    this.nickname,
    this.role,
    this.path,
    required this.status,
    this.model,
    this.reasoningEffort,
    this.preview,
    this.result,
    this.error,
    this.startedAt,
    this.updatedAt,
    this.completedAt,
    this.activeFlags = const <String>[],
  });

  factory SubagentInfo.fromJson(Map<String, dynamic> json) => SubagentInfo(
    threadId:
        _subagentNonEmptyString(
          json['threadId'] ?? json['id'] ?? json['receiverThreadId'],
        ) ??
        '',
    nickname: _subagentNonEmptyString(
      json['nickname'] ?? json['agentNickname'],
    ),
    role: _subagentNonEmptyString(json['role'] ?? json['agentRole']),
    path: _subagentNonEmptyString(json['path'] ?? json['agentPath']),
    status:
        _subagentNonEmptyString(json['status'] ?? json['state']) ?? 'unknown',
    model: _subagentNonEmptyString(json['model']),
    reasoningEffort: _subagentNonEmptyString(
      json['reasoningEffort'] ?? json['reasoning_effort'],
    ),
    preview: _subagentNonEmptyString(json['preview'] ?? json['prompt']),
    result: _subagentNonEmptyString(json['result']),
    error: _subagentNonEmptyString(json['error']),
    startedAt: _subagentDateString(json['startedAt'] ?? json['createdAt']),
    updatedAt: _subagentDateString(json['updatedAt']),
    completedAt: _subagentDateString(json['completedAt']),
    activeFlags: _subagentStringList(json['activeFlags']),
  );

  String get displayName {
    if (nickname != null) return nickname!;
    if (role != null) return role!;
    final segments = path?.split('/').where((part) => part.isNotEmpty).toList();
    if (segments != null && segments.isNotEmpty) return segments.last;
    return threadId;
  }

  bool get isActive =>
      activeFlags.isNotEmpty ||
      const {
        'active',
        'running',
        'pending',
        'starting',
        'working',
      }.contains(status.toLowerCase());
}

List<String> _subagentStringList(dynamic value) {
  if (value is! List) return const <String>[];
  return List<String>.unmodifiable(
    value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty && item.length <= 128),
  );
}

String? _subagentDateString(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final milliseconds = value.abs() < 100000000000
        ? value.toInt() * 1000
        : value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
      isUtc: true,
    ).toIso8601String();
  }
  return _subagentNonEmptyString(value);
}

String? _subagentNonEmptyString(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
