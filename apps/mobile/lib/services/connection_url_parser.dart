sealed class DeepLinkParams {}

class ConnectionParams extends DeepLinkParams {
  final String serverUrl;
  final String? token;
  final String? pairingToken;
  final String? bridgeIdentityId;
  final String? bridgeInstanceId;

  ConnectionParams({
    required this.serverUrl,
    this.token,
    this.pairingToken,
    this.bridgeIdentityId,
    this.bridgeInstanceId,
  });
}

class SessionLinkParams extends DeepLinkParams {
  final String sessionId;
  final String provider;
  final String? providerSessionId;
  final String? bridgeInstanceId;
  final String? codexSourceId;
  final String? bridgeRouteIdentity;

  SessionLinkParams({
    required this.sessionId,
    this.provider = 'claude',
    this.providerSessionId,
    this.bridgeInstanceId,
    this.codexSourceId,
    this.bridgeRouteIdentity,
  });
}

class ConnectionUrlParser {
  /// Parses a deep link URL into [DeepLinkParams].
  ///
  /// Supported formats:
  /// - `ccpocket://connect?url=ws://IP:PORT&token=...` → [ConnectionParams]
  /// - `ccpocket://session/<sessionId>?provider=codex` →
  ///   [SessionLinkParams]
  /// - `ws://IP:PORT` or `wss://IP:PORT` → [ConnectionParams]
  /// - `IP:PORT` (treated as ws://) → [ConnectionParams]
  static DeepLinkParams? parse(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;

    // Deep link: ccpocket://...
    if (trimmed.startsWith('ccpocket://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null) return null;

      // ccpocket://session/<sessionId>
      if (uri.host == 'session') {
        final segments = uri.pathSegments;
        if (segments.isEmpty) return null;
        final sessionId = segments.first;
        if (sessionId.isEmpty) return null;
        final provider = uri.queryParameters['provider'] == 'codex'
            ? 'codex'
            : 'claude';
        final providerSessionId = _boundedQueryParameter(
          uri,
          'providerSessionId',
          256,
        );
        final bridgeInstanceId = _boundedQueryParameter(
          uri,
          'bridgeInstanceId',
          256,
        );
        // A Codex source is authoritative only together with the stable Bridge
        // identity that attested it. Source-only links remain unscoped instead
        // of creating a false cross-Bridge identity.
        final codexSourceId = provider == 'codex' && bridgeInstanceId != null
            ? _boundedQueryParameter(uri, 'codexSourceId', 256)
            : null;
        // Modern durable identity wins when both modern and legacy fields are
        // present. Old Bridges may still use their credential-free route key.
        final bridgeRouteIdentity = bridgeInstanceId == null
            ? _boundedQueryParameter(uri, 'bridgeRouteIdentity', 1024)
            : null;
        return SessionLinkParams(
          sessionId: sessionId,
          provider: provider,
          providerSessionId: providerSessionId,
          bridgeInstanceId: bridgeInstanceId,
          codexSourceId: codexSourceId,
          bridgeRouteIdentity: bridgeRouteIdentity,
        );
      }

      // ccpocket://connect?url=...&token=...
      if (uri.host == 'connect') {
        final url = uri.queryParameters['url'];
        if (url == null || !_isValidWebSocketUrl(url)) return null;
        final token = uri.queryParameters['token'];
        return ConnectionParams(
          serverUrl: url,
          token: (token != null && token.isNotEmpty) ? token : null,
        );
      }

      // ccpocket://pair?url=...&token=...&bridgeIdentityId=...
      if (uri.host == 'pair') {
        final url = uri.queryParameters['url'];
        final pairingToken = _boundedQueryParameter(uri, 'token', 256);
        final bridgeIdentityId = _boundedQueryParameter(
          uri,
          'bridgeIdentityId',
          128,
        );
        final bridgeInstanceId = _boundedQueryParameter(
          uri,
          'bridgeInstanceId',
          256,
        );
        if (url == null ||
            !_isValidWebSocketUrl(url) ||
            pairingToken == null ||
            bridgeIdentityId == null ||
            bridgeInstanceId == null) {
          return null;
        }
        return ConnectionParams(
          serverUrl: url,
          pairingToken: pairingToken,
          bridgeIdentityId: bridgeIdentityId,
          bridgeInstanceId: bridgeInstanceId,
        );
      }

      return null;
    }

    // Direct ws:// or wss://
    if (trimmed.startsWith('ws://') || trimmed.startsWith('wss://')) {
      return _isValidWebSocketUrl(trimmed)
          ? ConnectionParams(serverUrl: trimmed)
          : null;
    }

    // Bare host:port
    final hostPortPattern = RegExp(r'^[\w.\-]+:\d+$');
    final bracketedIpv6PortPattern = RegExp(r'^\[[^\]]*:[^\]]*\]:\d+$');
    if (hostPortPattern.hasMatch(trimmed)) {
      return ConnectionParams(serverUrl: 'ws://$trimmed');
    }
    if (bracketedIpv6PortPattern.hasMatch(trimmed)) {
      try {
        final uri = Uri.parse('ws://$trimmed');
        if (uri.host.contains(':') &&
            uri.hasPort &&
            uri.port > 0 &&
            uri.port <= 65535) {
          return ConnectionParams(serverUrl: 'ws://$trimmed');
        }
      } on FormatException {
        return null;
      }
    }

    return null;
  }

  static bool _isValidWebSocketUrl(String value) {
    try {
      final uri = Uri.parse(value);
      if ((uri.scheme != 'ws' && uri.scheme != 'wss') || uri.host.isEmpty) {
        return false;
      }
      return !uri.hasPort || (uri.port > 0 && uri.port <= 65535);
    } on FormatException {
      return false;
    }
  }

  static String? _boundedQueryParameter(
    Uri uri,
    String name,
    int maximumLength,
  ) {
    final normalized = uri.queryParameters[name]?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized.length > maximumLength) {
      return null;
    }
    return normalized;
  }
}
