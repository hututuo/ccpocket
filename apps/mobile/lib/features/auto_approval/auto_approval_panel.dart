import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auto_approval_service.dart';
import 'auto_approval_strings.dart';

class AutoApprovalPanel extends StatelessWidget {
  const AutoApprovalPanel({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AutoApprovalService?>();
    if (service == null) return const SizedBox.shrink();
    final strings = AutoApprovalStrings.of(context);
    final available = service.canConfigureSession(sessionId);
    final enabled = service.isEnabledForSession(sessionId);
    final approvedCount = service.approvedCountForSession(sessionId);
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('auto_approval_switch'),
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: available
                ? (value) async {
                    final updated = await service.setEnabledForSession(
                      sessionId,
                      value,
                    );
                    if (!updated && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(strings.updateFailed)),
                      );
                    }
                  }
                : null,
            title: Text(strings.switchTitle),
            subtitle: Text(
              enabled
                  ? strings.enabledDescription
                  : strings.disabledDescription,
            ),
            secondary: Icon(
              enabled ? Icons.smart_toy_outlined : Icons.approval_outlined,
              color: enabled ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
          if (!available)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                strings.unavailable,
                key: const ValueKey('auto_approval_unavailable'),
                style: TextStyle(color: cs.error),
              ),
            ),
          if (enabled && approvedCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                strings.approvedCount(approvedCount),
                key: const ValueKey('auto_approval_count'),
                style: TextStyle(color: cs.primary),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.error.withValues(alpha: 0.32)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: cs.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.warningTitle,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(strings.warningBody),
                const SizedBox(height: 8),
                Text(strings.exclusions),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AutoApprovalStatusChip extends StatelessWidget {
  const AutoApprovalStatusChip({
    super.key,
    required this.sessionId,
    required this.onPressed,
  });

  final String sessionId;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AutoApprovalService?>();
    if (service == null) return const SizedBox.shrink();
    if (!service.isEnabledForSession(sessionId)) {
      return const SizedBox.shrink();
    }
    final strings = AutoApprovalStrings.of(context);
    return ActionChip(
      key: const ValueKey('auto_approval_status_chip'),
      avatar: const Icon(Icons.smart_toy_outlined, size: 16),
      label: Text(strings.statusEnabled),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    );
  }
}
