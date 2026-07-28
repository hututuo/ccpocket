import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import '../models/bridge_data_source_identity.dart';
import '../services/notification_service.dart';
import 'app_router.dart';

class SessionRouteObserver extends AutoRouterObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isTransientRoute(route)) return;
    _syncActiveSession(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isTransientRoute(route)) return;
    _syncActiveSession(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (_isTransientRoute(newRoute)) return;
    if (_isTransientRoute(oldRoute) && newRoute == null) return;
    _syncActiveSession(newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isTransientRoute(route)) return;
    _syncActiveSession(previousRoute);
  }

  bool _isTransientRoute(Route<dynamic>? route) => route is PopupRoute<dynamic>;

  void _syncActiveSession(Route<dynamic>? route) {
    if (route == null) {
      NotificationService.instance.clearActiveSession();
      return;
    }

    final settings = route.settings;
    final name = settings.name;
    final sessionId = _extractSessionId(settings.arguments);
    final dataSourceIdentity = _extractDataSourceIdentity(settings.arguments);

    if (sessionId == null || sessionId.isEmpty) {
      NotificationService.instance.clearActiveSession();
      return;
    }

    if (name == ClaudeSessionRoute.name) {
      NotificationService.instance.setActiveSession(
        sessionId: sessionId,
        provider: 'claude',
        dataSourceIdentity: dataSourceIdentity,
      );
      return;
    }
    if (name == CodexSessionRoute.name) {
      NotificationService.instance.setActiveSession(
        sessionId: sessionId,
        provider: 'codex',
        dataSourceIdentity: dataSourceIdentity,
      );
      return;
    }

    NotificationService.instance.clearActiveSession();
  }

  String? _extractSessionId(Object? arguments) {
    if (arguments == null) return null;

    if (arguments is Map) {
      return arguments['sessionId']?.toString();
    }

    try {
      final dynamic dynamicArgs = arguments;
      return dynamicArgs.sessionId?.toString();
    } catch (_) {
      return null;
    }
  }

  BridgeDataSourceIdentity _extractDataSourceIdentity(Object? arguments) {
    if (arguments is ClaudeSessionRouteArgs) {
      return arguments.dataSourceIdentity;
    }
    if (arguments is CodexSessionRouteArgs) {
      return arguments.dataSourceIdentity;
    }
    if (arguments is Map) {
      return BridgeDataSourceIdentity.fromMap(arguments);
    }
    try {
      final dynamic dynamicArgs = arguments;
      final identity = dynamicArgs.dataSourceIdentity;
      return identity is BridgeDataSourceIdentity
          ? identity
          : BridgeDataSourceIdentity.unscoped;
    } catch (_) {
      return BridgeDataSourceIdentity.unscoped;
    }
  }
}
