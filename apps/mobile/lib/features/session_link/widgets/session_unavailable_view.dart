import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

class SessionUnavailableView extends StatelessWidget {
  const SessionUnavailableView({
    super.key,
    required this.onOpenRecentSessions,
    this.onRetry,
    this.diagnosticText,
  });

  final VoidCallback onOpenRecentSessions;
  final VoidCallback? onRetry;
  final String? diagnosticText;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_off,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 20),
            Text(
              l.sessionUnavailableTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              l.sessionUnavailableDescription,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (diagnosticText?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 12),
              Text(
                diagnosticText!,
                key: const ValueKey('session_link_diagnostics'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                if (onRetry != null)
                  FilledButton.icon(
                    key: const ValueKey('retry_session_link_button'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text(l.retry),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('open_recent_sessions_button'),
                  onPressed: onOpenRecentSessions,
                  icon: const Icon(Icons.history),
                  label: Text(l.openRecentSessions),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
