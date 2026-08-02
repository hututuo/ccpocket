import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

enum BridgeConnectionKeyPromptAction { connect, scanQr }

class BridgeConnectionKeyPromptResult {
  const BridgeConnectionKeyPromptResult._(this.action, this.connectionKey);

  const BridgeConnectionKeyPromptResult.connect(String connectionKey)
    : this._(BridgeConnectionKeyPromptAction.connect, connectionKey);

  const BridgeConnectionKeyPromptResult.scanQr()
    : this._(BridgeConnectionKeyPromptAction.scanQr, null);

  final BridgeConnectionKeyPromptAction action;
  final String? connectionKey;
}

class BridgeConnectionKeyDialog extends StatefulWidget {
  const BridgeConnectionKeyDialog({super.key, required this.rejectedSavedKey});

  final bool rejectedSavedKey;

  @override
  State<BridgeConnectionKeyDialog> createState() =>
      _BridgeConnectionKeyDialogState();
}

class _BridgeConnectionKeyDialogState extends State<BridgeConnectionKeyDialog> {
  final _controller = TextEditingController();
  bool _hasValue = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _connect() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(BridgeConnectionKeyPromptResult.connect(value));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.bridgeConnectionKeyRequiredTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.rejectedSavedKey
                ? l.bridgeConnectionKeyRejectedBody
                : l.bridgeConnectionKeyMissingBody,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('bridge_connection_key_input'),
            controller: _controller,
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: l.bridgeConnectionKeyLabel,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              final next = value.trim().isNotEmpty;
              if (_hasValue != next) setState(() => _hasValue = next);
            },
            onSubmitted: (_) => _connect(),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('bridge_connection_key_scan_qr'),
          onPressed: () => Navigator.of(
            context,
          ).pop(const BridgeConnectionKeyPromptResult.scanQr()),
          child: Text(l.scanQrCode),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('bridge_connection_key_connect'),
          onPressed: _hasValue ? _connect : null,
          child: Text(l.connect),
        ),
      ],
    );
  }
}
