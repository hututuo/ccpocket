import 'package:flutter/material.dart';
import 'l10n/mobile_update_strings.dart';
import 'mobile_update_service.dart';

class MobileUpdateRestartPrompt extends StatefulWidget {
  const MobileUpdateRestartPrompt({
    required this.child,
    required this.service,
    super.key,
  });

  final Widget child;
  final MobileUpdateService service;

  @override
  State<MobileUpdateRestartPrompt> createState() =>
      _MobileUpdateRestartPromptState();
}

class _MobileUpdateRestartPromptState extends State<MobileUpdateRestartPrompt> {
  MobileUpdateService? _service;
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = widget.service;
    if (identical(next, _service)) return;
    _service?.removeListener(_handleUpdateState);
    _service = next..addListener(_handleUpdateState);
    _handleUpdateState();
  }

  @override
  void didUpdateWidget(covariant MobileUpdateRestartPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.service, widget.service)) return;
    oldWidget.service.removeListener(_handleUpdateState);
    _service = widget.service..addListener(_handleUpdateState);
    _handleUpdateState();
  }

  void _handleUpdateState() {
    final service = _service;
    if (service == null ||
        !service.state.shouldPromptRestart ||
        _scheduled ||
        !mounted) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !service.state.shouldPromptRestart) return;
      final l = MobileUpdateStrings.of(context);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const ValueKey('mobile_update_restart_prompt'),
            content: Text('${l.restartRequired}\n${l.restartMessage}'),
            action: SnackBarAction(label: l.dismiss, onPressed: () {}),
          ),
        );
      service.dismissRestartPrompt();
    });
  }

  @override
  void dispose() {
    _service?.removeListener(_handleUpdateState);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
