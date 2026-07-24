import 'package:flutter/material.dart';

import '../../../models/messages.dart';
import '../../../theme/app_theme.dart';

/// A thin glowing line at the bottom of the AppBar that indicates task status.
///
/// A genuinely running task is blue and gently pulses. Every non-running state
/// is a static gray so this signal cannot be confused with history syncing,
/// approvals, compaction, or startup.
class StatusLine extends StatefulWidget implements PreferredSizeWidget {
  final ProcessStatus status;
  final bool inPlanMode;

  const StatusLine({super.key, required this.status, this.inPlanMode = false});

  @override
  Size get preferredSize => const Size.fromHeight(2);

  @override
  State<StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<StatusLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;
  bool _tickerEnabled = true;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _glowAnimation = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    final media = MediaQuery.maybeOf(context);
    _reduceMotion =
        media?.disableAnimations == true || media?.accessibleNavigation == true;
    _synchronizeAnimation();
  }

  @override
  void didUpdateWidget(StatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronizeAnimation();
  }

  void _synchronizeAnimation() {
    if (_isActive &&
        _tickerEnabled &&
        !_reduceMotion &&
        !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if ((!_isActive || !_tickerEnabled || _reduceMotion) &&
        (_controller.isAnimating || _controller.value != 0)) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isActive => widget.status == ProcessStatus.running;

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;

    final color = _isActive ? appColors.statusRunning : appColors.statusIdle;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _glowAnimation,
        builder: (context, child) {
          final animate = _isActive && _tickerEnabled && !_reduceMotion;
          final glowOpacity = animate
              ? _glowAnimation.value
              : (_isActive ? 0.9 : 0.4);
          final blurRadius = animate ? 6.0 * _glowAnimation.value : 0.0;

          return Container(
            key: const ValueKey('session_status_line_surface'),
            height: 2,
            decoration: BoxDecoration(
              color: color.withValues(alpha: glowOpacity),
              boxShadow: [
                if (blurRadius > 0)
                  BoxShadow(
                    color: color.withValues(alpha: glowOpacity * 0.6),
                    blurRadius: blurRadius,
                    spreadRadius: 1,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
