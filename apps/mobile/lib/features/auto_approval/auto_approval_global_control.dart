import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auto_approval_service.dart';
import 'auto_approval_strings.dart';

/// App-level emergency stop for persisted conversation supervision.
///
/// This stays available in Settings without a Bridge connection or live
/// session list, so a stored approval scope can always be revoked first.
class AutoApprovalGlobalControl extends StatelessWidget {
  const AutoApprovalGlobalControl({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AutoApprovalService?>();
    if (service == null) return const SizedBox.shrink();
    final strings = AutoApprovalStrings.of(context);
    final count = service.enabledConversationCount;
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
          child: Text(
            strings.globalTitle.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: ListTile(
            key: const ValueKey('auto_approval_global_control'),
            leading: Icon(Icons.admin_panel_settings_outlined, color: cs.error),
            title: Text(
              count == 0
                  ? strings.globalNone
                  : strings.globalDescription(count),
            ),
            subtitle: Text(strings.exclusions),
            trailing: TextButton(
              key: const ValueKey('auto_approval_disable_all'),
              onPressed: count == 0
                  ? null
                  : () async {
                      final disabled = await service.disableAll();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            disabled
                                ? strings.disabledAll
                                : strings.disableAllFailed,
                          ),
                        ),
                      );
                    },
              child: Text(strings.disableAll),
            ),
          ),
        ),
      ],
    );
  }
}
