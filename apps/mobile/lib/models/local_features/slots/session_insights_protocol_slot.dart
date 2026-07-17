part of '../../messages.dart';

const LocalFeatureProtocolSlot sessionInsightsProtocolSlot =
    _SessionInsightsProtocolSlot();

class _SessionInsightsProtocolSlot
    implements LocalFeatureProtocolSlot, LocalFeatureRequestProtocolSlot {
  const _SessionInsightsProtocolSlot();

  @override
  String get featureId => 'session_insights';

  @override
  List<String> get supportedServerMessageTypes => const [
    'context_usage',
    'context_usage_result',
    'context_usage_error',
    'session_usage_result',
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) {
    return switch (json['type']) {
      'context_usage' => ContextUsageMessage(
        usage: ContextUsage.fromJson(json),
      ),
      'context_usage_result' => ContextUsageResultMessage.fromJson(json),
      'context_usage_error' => ContextUsageErrorMessage.fromJson(json),
      'session_usage_result' => SessionUsageResultMessage.fromJson(json),
      _ => null,
    };
  }

  @override
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request) {
    final type = request['type'];
    if (type != 'get_context_usage' && type != 'get_session_usage') {
      return null;
    }
    final sessionId = request['sessionId'];
    final requestId = request['requestId'];
    if (sessionId is! String || (requestId != null && requestId is! String)) {
      return null;
    }
    return LocalFeatureRequestDescriptor(
      featureId: featureId,
      requestType: type as String,
      ownerSessionId: sessionId,
      requestId: requestId as String?,
    );
  }

  @override
  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  ) {
    return switch (request.requestType) {
      'get_context_usage' =>
        (response is ContextUsageResultMessage ||
                response is ContextUsageErrorMessage) &&
            (response as LocalFeatureServerMessage).sessionId ==
                request.ownerSessionId,
      'get_session_usage' =>
        response is SessionUsageResultMessage &&
            response.sessionId == request.ownerSessionId &&
            response.requestId == request.requestId,
      _ => false,
    };
  }

  @override
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  ) {
    return switch (request.requestType) {
      'get_context_usage' => false,
      'get_session_usage' =>
        error.errorCode == 'unsupported_capability' &&
            error.message == 'Session usage capability was not negotiated',
      _ => false,
    };
  }
}

ClientMessage requestContextUsage(String sessionId) {
  _requireSessionInsightsId(sessionId, 'sessionId', 256);
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'get_context_usage',
    sessionId: sessionId,
  );
}

ClientMessage requestSessionUsage({
  required String sessionId,
  required String requestId,
}) {
  _requireSessionInsightsId(sessionId, 'sessionId', 256);
  _requireSessionInsightsId(requestId, 'requestId', 128);
  return LocalFeatureProtocolHost.ephemeralRequest(
    type: 'get_session_usage',
    sessionId: sessionId,
    requestId: requestId,
  );
}

void _requireSessionInsightsId(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw ArgumentError.value(value, name, 'must be non-empty and bounded');
  }
}

class ContextUsageMessage implements LocalFeatureTransientMessage {
  final ContextUsage usage;

  const ContextUsageMessage({required this.usage});

  @override
  String get featureId => 'session_insights';

  @override
  String? get sessionId => usage.sessionId;
  String? get threadId => usage.threadId;
  String? get turnId => usage.turnId;
  ContextTokenUsage get last => usage.last;
  ContextTokenUsage get total => usage.total;
  int get modelContextWindow => usage.modelContextWindow;
}

/// Correlated response to an explicit bounded context read.
class ContextUsageResultMessage implements LocalFeatureTransientMessage {
  @override
  final String sessionId;
  final ContextUsage usage;

  const ContextUsageResultMessage({
    required this.sessionId,
    required this.usage,
  });

  @override
  String get featureId => 'session_insights';

  factory ContextUsageResultMessage.fromJson(Map<String, dynamic> json) {
    final sessionId = _sessionUsageNonEmptyString(json['sessionId']);
    if (sessionId == null) {
      throw const FormatException(
        'context_usage_result requires non-empty sessionId',
      );
    }
    return ContextUsageResultMessage(
      sessionId: sessionId,
      usage: ContextUsage.fromJson(json),
    );
  }
}

class ContextUsageErrorMessage implements LocalFeatureTransientMessage {
  @override
  final String sessionId;
  final String errorCode;
  final String message;

  const ContextUsageErrorMessage({
    required this.sessionId,
    required this.errorCode,
    required this.message,
  });

  @override
  String get featureId => 'session_insights';

  factory ContextUsageErrorMessage.fromJson(Map<String, dynamic> json) {
    final sessionId = _sessionUsageNonEmptyString(json['sessionId']);
    final errorCode = _sessionUsageNonEmptyString(json['errorCode']);
    final message = _sessionUsageNonEmptyString(json['message']);
    if (sessionId == null || errorCode == null || message == null) {
      throw const FormatException(
        'context_usage_error requires sessionId, errorCode, and message',
      );
    }
    return ContextUsageErrorMessage(
      sessionId: sessionId,
      errorCode: errorCode,
      message: message,
    );
  }
}

/// Feature-local quota window for the optional session-insights protocol.
///
/// This intentionally does not extend the upstream [UsageWindow] model. The
/// whole session-insights protocol can therefore be removed without changing
/// the official `usage_result` contract.
class SessionUsageWindow {
  final double utilization;
  final String? resetsAt;
  final int? windowDurationMins;

  const SessionUsageWindow({
    required this.utilization,
    this.resetsAt,
    this.windowDurationMins,
  });

  factory SessionUsageWindow.fromJson(Map<String, dynamic> json) =>
      SessionUsageWindow(
        utilization: (json['utilization'] as num?)?.toDouble() ?? 0,
        resetsAt: _sessionUsageDateString(
          json['resetsAt'] ?? json['resets_at'],
        ),
        windowDurationMins: _sessionUsageIntOrNull(
          json['windowDurationMins'] ?? json['window_duration_mins'],
        ),
      );

  DateTime? get resetsAtDateTime =>
      resetsAt == null ? null : DateTime.tryParse(resetsAt!);
}

class SessionUsageLimitCard {
  final String id;
  final String? name;
  final String? limitName;
  final String? planType;
  final SessionUsageWindow? fiveHour;
  final SessionUsageWindow? sevenDay;
  final String? rateLimitReachedType;
  final bool? spendControlReached;
  final Object? individualLimit;

  const SessionUsageLimitCard({
    required this.id,
    this.name,
    this.limitName,
    this.planType,
    this.fiveHour,
    this.sevenDay,
    this.rateLimitReachedType,
    this.spendControlReached,
    this.individualLimit,
  });

  factory SessionUsageLimitCard.fromJson(Map<String, dynamic> json) {
    final fiveHourJson = _sessionUsageStringKeyedMap(
      json['fiveHour'] ?? json['primary'],
    );
    final sevenDayJson = _sessionUsageStringKeyedMap(
      json['sevenDay'] ?? json['secondary'],
    );
    return SessionUsageLimitCard(
      id: _sessionUsageNonEmptyString(json['id'] ?? json['limitId']) ?? '',
      name: _sessionUsageNonEmptyString(json['name']),
      limitName: _sessionUsageNonEmptyString(json['limitName']),
      planType: _sessionUsageNonEmptyString(json['planType']),
      fiveHour: fiveHourJson == null
          ? null
          : SessionUsageWindow.fromJson(fiveHourJson),
      sevenDay: sevenDayJson == null
          ? null
          : SessionUsageWindow.fromJson(sevenDayJson),
      rateLimitReachedType: _sessionUsageNonEmptyString(
        json['rateLimitReachedType'],
      ),
      spendControlReached: json['spendControlReached'] as bool?,
      individualLimit: json['individualLimit'],
    );
  }

  String get displayName =>
      limitName ?? name ?? planType ?? (id.isEmpty ? 'Codex' : id);

  bool get hasData => fiveHour != null || sevenDay != null;
}

/// A reset credit is display-only. The mobile client exposes no redeem action.
class SessionUsageResetCredit {
  final String id;
  final String status;
  final String? resetType;
  final String? grantedAt;
  final String? expiresAt;
  final String? redeemStartedAt;
  final String? redeemedAt;
  final String? title;
  final String? description;
  final String? profileUserId;
  final String? profileImageUrl;
  final String? source;

  const SessionUsageResetCredit({
    required this.id,
    required this.status,
    this.resetType,
    this.grantedAt,
    this.expiresAt,
    this.redeemStartedAt,
    this.redeemedAt,
    this.title,
    this.description,
    this.profileUserId,
    this.profileImageUrl,
    this.source,
  });

  factory SessionUsageResetCredit.fromJson(
    Map<String, dynamic> json,
  ) => SessionUsageResetCredit(
    id: _sessionUsageNonEmptyString(json['id']) ?? '',
    status: _sessionUsageNonEmptyString(json['status']) ?? '',
    resetType: _sessionUsageNonEmptyString(
      json['resetType'] ?? json['reset_type'],
    ),
    grantedAt: _sessionUsageDateString(json['grantedAt'] ?? json['granted_at']),
    expiresAt: _sessionUsageDateString(json['expiresAt'] ?? json['expires_at']),
    redeemStartedAt: _sessionUsageDateString(
      json['redeemStartedAt'] ?? json['redeem_started_at'],
    ),
    redeemedAt: _sessionUsageDateString(
      json['redeemedAt'] ?? json['redeemed_at'],
    ),
    title: _sessionUsageNonEmptyString(json['title']),
    description: _sessionUsageNonEmptyString(
      json['description'] ?? json['descriptionText'],
    ),
    profileUserId: _sessionUsageNonEmptyString(
      json['profileUserId'] ?? json['profileUserID'] ?? json['profile_user_id'],
    ),
    profileImageUrl: _sessionUsageNonEmptyString(
      json['profileImageUrl'] ??
          json['profileImageURL'] ??
          json['profile_image_url'],
    ),
    source: _sessionUsageNonEmptyString(json['source']),
  );

  DateTime? get expiresAtDateTime =>
      expiresAt == null ? null : DateTime.tryParse(expiresAt!);

  bool get isAvailable => status == 'available' && redeemedAt == null;
}

class SessionUsageResetCredits {
  final int availableCount;
  final List<SessionUsageResetCredit> credits;

  const SessionUsageResetCredits({
    required this.availableCount,
    this.credits = const [],
  });

  factory SessionUsageResetCredits.fromJson(Map<String, dynamic> json) {
    final credits =
        (json['credits'] as List?)
            ?.whereType<Map>()
            .map(
              (item) => SessionUsageResetCredit.fromJson(
                Map<String, dynamic>.from(item),
              ),
            )
            .where((credit) => credit.id.isNotEmpty)
            .toList(growable: false) ??
        const <SessionUsageResetCredit>[];
    final reported = _sessionUsageIntOrNull(
      json['availableCount'] ?? json['available_count'],
    );
    return SessionUsageResetCredits(
      availableCount: reported == null
          ? credits.where((credit) => credit.isAvailable).length
          : reported.clamp(0, 1 << 31).toInt(),
      credits: credits,
    );
  }
}

class SessionUsageInfo {
  final String provider;
  final SessionUsageWindow? fiveHour;
  final SessionUsageWindow? sevenDay;
  final List<SessionUsageLimitCard> limitCards;
  final SessionUsageResetCredits? resetCredits;
  final String? source;
  final String? error;

  const SessionUsageInfo({
    required this.provider,
    this.fiveHour,
    this.sevenDay,
    this.limitCards = const [],
    this.resetCredits,
    this.source,
    this.error,
  });

  factory SessionUsageInfo.fromJson(Map<String, dynamic> json) {
    final cards =
        (json['limitCards'] as List?)
            ?.whereType<Map>()
            .map(
              (item) => SessionUsageLimitCard.fromJson(
                Map<String, dynamic>.from(item),
              ),
            )
            .where((card) => card.hasData)
            .toList(growable: false) ??
        const <SessionUsageLimitCard>[];
    final fiveHour = _sessionUsageStringKeyedMap(json['fiveHour']);
    final sevenDay = _sessionUsageStringKeyedMap(json['sevenDay']);
    final resetCredits = _sessionUsageResetCreditsFromValue(
      json['resetCredits'],
    );
    return SessionUsageInfo(
      provider: _sessionUsageNonEmptyString(json['provider']) ?? '',
      fiveHour: fiveHour == null ? null : SessionUsageWindow.fromJson(fiveHour),
      sevenDay: sevenDay == null ? null : SessionUsageWindow.fromJson(sevenDay),
      limitCards: cards,
      resetCredits: resetCredits,
      source: _sessionUsageNonEmptyString(json['source']),
      error: _sessionUsageNonEmptyString(json['error']),
    );
  }

  bool get hasData =>
      fiveHour != null ||
      sevenDay != null ||
      limitCards.isNotEmpty ||
      resetCredits != null;

  bool get hasError => error != null && !hasData;
}

/// A correlated one-shot response for the optional session-insights feature.
class SessionUsageResultMessage implements LocalFeatureTransientMessage {
  @override
  final String sessionId;
  final String requestId;
  final List<SessionUsageInfo> providers;
  final String? error;

  const SessionUsageResultMessage({
    required this.sessionId,
    required this.requestId,
    required this.providers,
    this.error,
  });

  @override
  String get featureId => 'session_insights';

  factory SessionUsageResultMessage.fromJson(Map<String, dynamic> json) {
    final sessionId = _sessionUsageNonEmptyString(json['sessionId']);
    final requestId = _sessionUsageNonEmptyString(json['requestId']);
    if (sessionId == null || requestId == null) {
      throw const FormatException(
        'session_usage_result requires non-empty sessionId and requestId',
      );
    }
    final providers =
        (json['providers'] as List?)
            ?.whereType<Map>()
            .map(
              (provider) => SessionUsageInfo.fromJson(
                Map<String, dynamic>.from(provider),
              ),
            )
            .toList(growable: false) ??
        const <SessionUsageInfo>[];
    return SessionUsageResultMessage(
      sessionId: sessionId,
      requestId: requestId,
      providers: providers,
      error: _sessionUsageNonEmptyString(json['error']),
    );
  }
}

SessionUsageResetCredits? _sessionUsageResetCreditsFromValue(dynamic value) {
  final map = _sessionUsageStringKeyedMap(value);
  if (map != null) return SessionUsageResetCredits.fromJson(map);
  if (value is List) {
    return SessionUsageResetCredits.fromJson(<String, dynamic>{
      'credits': value,
    });
  }
  return null;
}

int? _sessionUsageIntOrNull(dynamic value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

String? _sessionUsageDateString(dynamic value) {
  if (value == null) return null;
  if (value is num && value.isFinite) {
    final milliseconds = value.abs() < 100000000000
        ? value.toInt() * 1000
        : value.toInt();
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      ).toIso8601String();
    } on RangeError {
      return null;
    }
  }
  return _sessionUsageNonEmptyString(value);
}

Map<String, dynamic>? _sessionUsageStringKeyedMap(dynamic value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String? _sessionUsageNonEmptyString(dynamic value) {
  if (value is! String) {
    return value?.toString().trim().isEmpty == false
        ? value.toString().trim()
        : null;
  }
  final text = value.trim();
  return text.isEmpty ? null : text;
}
