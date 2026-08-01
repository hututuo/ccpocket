part of '../../messages.dart';

// Read-only context-window models used by the session-insights UI. Existing
// UsageInfo/UsageWindow protocol models remain in messages.dart so removing
// this feature does not move or strand an upstream-owned model.

class ContextTokenUsage {
  final int inputTokens;
  final int cachedInputTokens;
  final int outputTokens;
  final int reasoningOutputTokens;
  final int totalTokens;

  const ContextTokenUsage({
    this.inputTokens = 0,
    this.cachedInputTokens = 0,
    this.outputTokens = 0,
    this.reasoningOutputTokens = 0,
    this.totalTokens = 0,
  });

  factory ContextTokenUsage.fromJson(Map<String, dynamic> json) {
    final input =
        _sessionInsightsIntOrNull(
          json['inputTokens'] ?? json['input_tokens'],
        ) ??
        0;
    final cached =
        _sessionInsightsIntOrNull(
          json['cachedInputTokens'] ?? json['cached_input_tokens'],
        ) ??
        0;
    final output =
        _sessionInsightsIntOrNull(
          json['outputTokens'] ?? json['output_tokens'],
        ) ??
        0;
    final reasoning =
        _sessionInsightsIntOrNull(
          json['reasoningOutputTokens'] ??
              json['reasoningTokens'] ??
              json['reasoning_output_tokens'],
        ) ??
        0;
    return ContextTokenUsage(
      inputTokens: input,
      cachedInputTokens: cached,
      outputTokens: output,
      reasoningOutputTokens: reasoning,
      totalTokens:
          _sessionInsightsIntOrNull(
            json['totalTokens'] ?? json['total_tokens'],
          ) ??
          input + output,
    );
  }
}

class ContextUsage {
  final String? sessionId;
  final String? threadId;
  final String? turnId;
  final String? bridgeInstanceId;
  final String? codexSourceId;
  final String? authorityGeneration;
  final ContextTokenUsage last;
  final ContextTokenUsage total;
  final int modelContextWindow;

  const ContextUsage({
    this.sessionId,
    this.threadId,
    this.turnId,
    this.bridgeInstanceId,
    this.codexSourceId,
    this.authorityGeneration,
    required this.last,
    required this.total,
    required this.modelContextWindow,
  });

  factory ContextUsage.fromJson(Map<String, dynamic> json) {
    final usage =
        _sessionInsightsStringKeyedMap(json['usage']) ??
        const <String, dynamic>{};
    final lastJson =
        _sessionInsightsStringKeyedMap(json['last']) ??
        _sessionInsightsStringKeyedMap(usage['last']) ??
        const <String, dynamic>{};
    final totalJson =
        _sessionInsightsStringKeyedMap(json['total']) ??
        _sessionInsightsStringKeyedMap(usage['total']) ??
        const <String, dynamic>{};
    return ContextUsage(
      sessionId: _sessionInsightsNonEmptyString(json['sessionId']),
      threadId: _sessionInsightsNonEmptyString(json['threadId']),
      turnId: _sessionInsightsNonEmptyString(json['turnId']),
      bridgeInstanceId: _sessionInsightsNonEmptyString(
        json['bridgeInstanceId'],
      ),
      codexSourceId: _sessionInsightsNonEmptyString(json['codexSourceId']),
      authorityGeneration: _sessionInsightsNonEmptyString(
        json['authorityGeneration'],
      ),
      last: ContextTokenUsage.fromJson(lastJson),
      total: ContextTokenUsage.fromJson(totalJson),
      modelContextWindow:
          _sessionInsightsIntOrNull(
            json['modelContextWindow'] ?? usage['modelContextWindow'],
          ) ??
          0,
    );
  }

  double get utilization {
    if (modelContextWindow <= 0) return 0;
    return (last.totalTokens / modelContextWindow).clamp(0, 1).toDouble();
  }
}

int? _sessionInsightsIntOrNull(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Map<String, dynamic>? _sessionInsightsStringKeyedMap(dynamic value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String? _sessionInsightsNonEmptyString(dynamic value) {
  if (value is! String) {
    return value?.toString().trim().isEmpty == false
        ? value.toString().trim()
        : null;
  }
  final text = value.trim();
  return text.isEmpty ? null : text;
}
