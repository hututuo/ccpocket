import 'package:flutter/material.dart';

/// Reasserts a durable conversation's focus when a covered route becomes
/// current again.
///
/// A pushed conversation replaces the single Bridge focus target without
/// disposing the previous route. Listening to the previous route's secondary
/// animation catches the later Navigator pop without requiring a global route
/// observer or coupling the sync service to app navigation.
class ConversationRouteFocusRestorer extends StatefulWidget {
  const ConversationRouteFocusRestorer({
    super.key,
    required this.onRouteCurrent,
    required this.child,
  });

  final VoidCallback onRouteCurrent;
  final Widget child;

  @override
  State<ConversationRouteFocusRestorer> createState() =>
      _ConversationRouteFocusRestorerState();
}

class _ConversationRouteFocusRestorerState
    extends State<ConversationRouteFocusRestorer> {
  ModalRoute<dynamic>? _route;
  Animation<double>? _secondaryAnimation;
  bool _reportedCurrentExposure = false;
  bool _callbackScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextRoute = ModalRoute.of(context);
    if (!identical(_route, nextRoute)) {
      _secondaryAnimation?.removeListener(_handleRouteAnimation);
      _route = nextRoute;
      _secondaryAnimation = nextRoute?.secondaryAnimation
        ?..addListener(_handleRouteAnimation);
      _reportedCurrentExposure = false;
    }
    _evaluateRouteCurrent();
  }

  void _handleRouteAnimation() => _evaluateRouteCurrent();

  void _evaluateRouteCurrent() {
    final route = _route;
    final isCurrent = route?.isCurrent ?? true;
    if (!isCurrent) {
      _reportedCurrentExposure = false;
      return;
    }
    if (_reportedCurrentExposure || _callbackScheduled) return;
    _callbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _callbackScheduled = false;
      if (!mounted || !identical(_route, route)) return;
      if (route?.isCurrent == false) {
        _reportedCurrentExposure = false;
        return;
      }
      _reportedCurrentExposure = true;
      widget.onRouteCurrent();
    });
  }

  @override
  void dispose() {
    _secondaryAnimation?.removeListener(_handleRouteAnimation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
