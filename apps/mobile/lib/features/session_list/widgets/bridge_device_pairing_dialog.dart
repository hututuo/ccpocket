import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/bridge_service.dart';

Future<void> showBridgeDevicePairingDialog({
  required BuildContext context,
  required BridgeService bridge,
  required BridgeDevicePairingSnapshot initial,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _BridgeDevicePairingDialog(bridge: bridge, initial: initial),
  );
}

class _BridgeDevicePairingDialog extends StatefulWidget {
  const _BridgeDevicePairingDialog({
    required this.bridge,
    required this.initial,
  });

  final BridgeService bridge;
  final BridgeDevicePairingSnapshot initial;

  @override
  State<_BridgeDevicePairingDialog> createState() =>
      _BridgeDevicePairingDialogState();
}

class _BridgeDevicePairingDialogState
    extends State<_BridgeDevicePairingDialog> {
  late BridgeDevicePairingSnapshot _snapshot = widget.initial;
  StreamSubscription<BridgeDevicePairingSnapshot>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.bridge.devicePairingChanges.listen((snapshot) {
      if (!mounted ||
          snapshot.connectionEpoch != widget.initial.connectionEpoch) {
        return;
      }
      if (snapshot.phase == BridgeDevicePairingPhase.authenticated) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _snapshot = snapshot);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final code = _snapshot.confirmationCode;
    final failed =
        _snapshot.phase == BridgeDevicePairingPhase.failed ||
        _snapshot.phase == BridgeDevicePairingPhase.rejected;
    final command = code == null ? null : 'ccpocket-bridge pair approve $code';
    return AlertDialog(
      title: Text(l.bridgePairingTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              failed
                  ? (_snapshot.message ?? l.bridgePairingFailed)
                  : l.bridgePairingBody,
            ),
            if (!failed && code != null) ...[
              const SizedBox(height: 18),
              Text(
                l.bridgePairingCodeLabel,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              SelectableText(
                code,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 12),
              Text(l.bridgePairingCommandHint),
              const SizedBox(height: 6),
              SelectableText(
                command!,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.bridgePairingWaiting)),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!failed && command != null)
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
            icon: const Icon(Icons.copy_rounded),
            label: Text(l.bridgePairingCopyCommand),
          ),
        TextButton(
          onPressed: () {
            if (!failed) widget.bridge.disconnect();
            Navigator.of(context).pop();
          },
          child: Text(failed ? l.close : l.cancel),
        ),
      ],
    );
  }
}
