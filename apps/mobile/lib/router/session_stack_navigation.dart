import 'dart:collection';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';

import '../models/bridge_data_source_identity.dart';
import 'app_router.dart';

@immutable
class SessionRouteIdentity {
  final String sessionId;
  final String provider;
  final BridgeDataSourceIdentity dataSourceIdentity;

  const SessionRouteIdentity({
    required this.sessionId,
    required this.provider,
    this.dataSourceIdentity = BridgeDataSourceIdentity.unscoped,
  });

  bool matches({
    required String sessionId,
    required String provider,
    BridgeDataSourceIdentity requestedDataSourceIdentity =
        BridgeDataSourceIdentity.unscoped,
  }) {
    return this.sessionId == sessionId &&
        this.provider == provider &&
        dataSourceIdentity.matchesRequest(
          requestedDataSourceIdentity,
          provider: provider,
        );
  }
}

class SessionRouteRegistry {
  SessionRouteRegistry._();

  static final SessionRouteRegistry instance = SessionRouteRegistry._();

  final Map<Object, ({Object owner, SessionRouteIdentity identity})> _routes =
      HashMap.identity();

  void update({
    required Object routeIdentity,
    required Object owner,
    required String sessionId,
    required String provider,
    BridgeDataSourceIdentity dataSourceIdentity =
        BridgeDataSourceIdentity.unscoped,
  }) {
    _routes[routeIdentity] = (
      owner: owner,
      identity: SessionRouteIdentity(
        sessionId: sessionId,
        provider: provider,
        dataSourceIdentity: dataSourceIdentity,
      ),
    );
  }

  void remove({required Object routeIdentity, required Object owner}) {
    final registered = _routes[routeIdentity];
    if (registered != null && identical(registered.owner, owner)) {
      _routes.remove(routeIdentity);
    }
  }

  SessionRouteIdentity? identityFor(Object routeIdentity) {
    return _routes[routeIdentity]?.identity;
  }

  @visibleForTesting
  void clear() {
    _routes.clear();
  }
}

class SessionStackNavigation {
  const SessionStackNavigation._();

  static bool revealStackedSession(
    StackRouter router, {
    required String sessionId,
    required String provider,
    BridgeDataSourceIdentity dataSourceIdentity =
        BridgeDataSourceIdentity.unscoped,
  }) {
    final rootRouter = router.root;
    final targetIndex = rootRouter.stack.indexWhere(
      (page) => matchesDestination(
        routeIdentity: page,
        routeName: page.routeData.name,
        arguments: page.routeData.args,
        sessionId: sessionId,
        provider: provider,
        dataSourceIdentity: dataSourceIdentity,
      ),
    );
    if (targetIndex == -1 || rootRouter.navigatorKey.currentState == null) {
      return false;
    }

    final targetPage = rootRouter.stack[targetIndex];
    rootRouter.popUntil((route) => identical(route.settings, targetPage));
    return true;
  }

  @visibleForTesting
  static bool matchesDestination({
    required Object routeIdentity,
    required String routeName,
    required Object? arguments,
    required String sessionId,
    required String provider,
    BridgeDataSourceIdentity dataSourceIdentity =
        BridgeDataSourceIdentity.unscoped,
  }) {
    final liveIdentity = SessionRouteRegistry.instance.identityFor(
      routeIdentity,
    );
    if (liveIdentity != null) {
      return liveIdentity.matches(
        sessionId: sessionId,
        provider: provider,
        requestedDataSourceIdentity: dataSourceIdentity,
      );
    }
    // Generated route arguments from older builds do not carry a trustworthy
    // source identity. A source-aware request must wait for the live screen
    // registry instead of reusing a same-ID route from another Codex source.
    if (dataSourceIdentity.isScoped) return false;
    if (routeName == ClaudeSessionRoute.name &&
        provider == 'claude' &&
        arguments is ClaudeSessionRouteArgs) {
      return arguments.sessionId == sessionId;
    }
    if (routeName == CodexSessionRoute.name &&
        provider == 'codex' &&
        arguments is CodexSessionRouteArgs) {
      return arguments.sessionId == sessionId;
    }
    return false;
  }
}
