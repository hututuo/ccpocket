import 'package:flutter/foundation.dart';

/// Identifies the authoritative data source behind one Mobile connection.
///
/// Modern Bridges expose a durable [bridgeInstanceId] and, for Codex data, a
/// [codexSourceId]. Older Bridges fall back to a local route identity so their
/// existing behavior remains available without pretending that an endpoint is
/// an authenticated source identity.
@immutable
class BridgeDataSourceIdentity {
  static const unscoped = BridgeDataSourceIdentity();

  final String? bridgeInstanceId;
  final String? codexSourceId;
  final String? legacyRouteIdentity;

  const BridgeDataSourceIdentity({
    this.bridgeInstanceId,
    this.codexSourceId,
    this.legacyRouteIdentity,
  });

  factory BridgeDataSourceIdentity.fromConnection({
    String? bridgeInstanceId,
    String? codexSourceId,
    String? logicalConnectionIdentity,
    String? websocketUrl,
  }) {
    final normalizedBridgeId = _boundedString(bridgeInstanceId, 256);
    return BridgeDataSourceIdentity(
      bridgeInstanceId: normalizedBridgeId,
      codexSourceId: normalizedBridgeId == null
          ? null
          : _boundedString(codexSourceId, 256),
      legacyRouteIdentity: _legacyRouteIdentity(
        logicalConnectionIdentity: logicalConnectionIdentity,
        websocketUrl: websocketUrl,
      ),
    );
  }

  factory BridgeDataSourceIdentity.fromMap(Map<dynamic, dynamic> data) {
    final bridgeInstanceId = _boundedString(data['bridgeInstanceId'], 256);
    return BridgeDataSourceIdentity(
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: bridgeInstanceId == null
          ? null
          : _boundedString(data['codexSourceId'], 256),
      legacyRouteIdentity: bridgeInstanceId == null
          ? _boundedString(data['bridgeRouteIdentity'], 1024)
          : null,
    );
  }

  bool get isScoped =>
      _normalizedBridgeInstanceId != null ||
      _normalizedLegacyRouteIdentity != null;

  String get connectionScopeKey => scopeKeyForProvider('codex');

  /// Stable storage scope for provider-owned data.
  ///
  /// Claude data is partitioned by Bridge. Codex data additionally includes
  /// its explicit source so two sequential Cockpit instances can share one
  /// source without leaking into a different source hosted by the same Bridge.
  String scopeKeyForProvider(String provider) {
    final bridgeId = _normalizedBridgeInstanceId;
    if (bridgeId != null) {
      final bridgeScope = 'bridge:${Uri.encodeComponent(bridgeId)}';
      if (provider != 'codex') return bridgeScope;
      final sourceId = _normalizedCodexSourceId;
      return sourceId == null
          ? '$bridgeScope|codex:legacy'
          : '$bridgeScope|codex:${Uri.encodeComponent(sourceId)}';
    }
    return _normalizedLegacyRouteIdentity ?? 'unknown-bridge';
  }

  /// Whether this bound identity can satisfy [requested].
  ///
  /// An unscoped request represents an old notification/client and keeps the
  /// previous best-effort behavior. Once the requester supplies a durable
  /// identity, missing or different authoritative fields fail closed.
  bool matchesRequest(
    BridgeDataSourceIdentity requested, {
    required String provider,
  }) {
    final requestedBridgeId = requested._normalizedBridgeInstanceId;
    if (requestedBridgeId != null) {
      if (_normalizedBridgeInstanceId != requestedBridgeId) return false;
      final requestedSourceId = requested._normalizedCodexSourceId;
      if (provider == 'codex' && requestedSourceId != null) {
        return _normalizedCodexSourceId == requestedSourceId;
      }
      return true;
    }

    final requestedLegacyRoute = requested._normalizedLegacyRouteIdentity;
    if (requestedLegacyRoute != null) {
      return _normalizedBridgeInstanceId == null &&
          _normalizedLegacyRouteIdentity == requestedLegacyRoute;
    }
    return true;
  }

  /// Whether a payload carrying this expected identity may target [current].
  bool isSatisfiedBy(
    BridgeDataSourceIdentity current, {
    required String provider,
  }) {
    if (!isScoped) return true;
    return current.matchesRequest(this, provider: provider);
  }

  /// Replaces a provisional route/cache identity with an authenticated one
  /// only when doing so cannot cross a known Bridge or Codex source boundary.
  ///
  /// The caller must still prove that the requested provider thread exists in
  /// the authenticated catalog. This deliberately refuses to reconcile two
  /// different non-empty Codex source IDs.
  BridgeDataSourceIdentity reconciledWithAuthenticated(
    BridgeDataSourceIdentity authenticated, {
    required String provider,
  }) {
    final authenticatedBridgeId =
        authenticated._normalizedBridgeInstanceId;
    if (authenticatedBridgeId == null) return this;

    final currentBridgeId = _normalizedBridgeInstanceId;
    if (currentBridgeId != null && currentBridgeId != authenticatedBridgeId) {
      return this;
    }

    if (currentBridgeId == null) {
      final currentRoute = _normalizedLegacyRouteIdentity;
      final authenticatedRoute = authenticated._normalizedLegacyRouteIdentity;
      if (currentRoute != null && currentRoute != authenticatedRoute) {
        return this;
      }
    }

    if (provider == 'codex') {
      final currentSourceId = _normalizedCodexSourceId;
      final authenticatedSourceId = authenticated._normalizedCodexSourceId;
      if (currentSourceId != null &&
          authenticatedSourceId != null &&
          currentSourceId != authenticatedSourceId) {
        return this;
      }
      if (currentSourceId != null && authenticatedSourceId == null) {
        return this;
      }
    }

    return authenticated;
  }

  Map<String, String> toNotificationFields() {
    final bridgeId = _normalizedBridgeInstanceId;
    if (bridgeId != null) {
      final sourceId = _normalizedCodexSourceId;
      final fields = <String, String>{'bridgeInstanceId': bridgeId};
      if (sourceId != null) {
        fields['codexSourceId'] = sourceId;
      }
      return fields;
    }
    final routeIdentity = _normalizedLegacyRouteIdentity;
    if (routeIdentity == null) return <String, String>{};
    return <String, String>{'bridgeRouteIdentity': routeIdentity};
  }

  String notificationDiscriminatorForProvider(String provider) {
    final bridgeId = _normalizedBridgeInstanceId;
    if (bridgeId != null) {
      return provider == 'codex'
          ? '$bridgeId|${_normalizedCodexSourceId ?? ''}'
          : bridgeId;
    }
    return _normalizedLegacyRouteIdentity ?? '';
  }

  String? get _normalizedBridgeInstanceId =>
      _boundedString(bridgeInstanceId, 256);

  String? get _normalizedCodexSourceId => _normalizedBridgeInstanceId == null
      ? null
      : _boundedString(codexSourceId, 256);

  String? get _normalizedLegacyRouteIdentity =>
      _boundedString(legacyRouteIdentity, 1024);

  static String? _legacyRouteIdentity({
    required String? logicalConnectionIdentity,
    required String? websocketUrl,
  }) {
    final logical = _boundedString(logicalConnectionIdentity, 512);
    if (logical != null) return 'logical:$logical';

    final uri = websocketUrl == null ? null : Uri.tryParse(websocketUrl);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort
        ? uri.port
        : switch (scheme) {
            'wss' => 443,
            _ => 80,
          };
    return 'url:$scheme://${uri.host.toLowerCase()}:$port${uri.path}';
  }

  static String? _boundedString(Object? value, int maximumLength) {
    if (value is! String) return null;
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > maximumLength) return null;
    return normalized;
  }

  @override
  bool operator ==(Object other) =>
      other is BridgeDataSourceIdentity &&
      other._normalizedBridgeInstanceId == _normalizedBridgeInstanceId &&
      other._normalizedCodexSourceId == _normalizedCodexSourceId &&
      other._normalizedLegacyRouteIdentity == _normalizedLegacyRouteIdentity;

  @override
  int get hashCode => Object.hash(
    _normalizedBridgeInstanceId,
    _normalizedCodexSourceId,
    _normalizedLegacyRouteIdentity,
  );
}
