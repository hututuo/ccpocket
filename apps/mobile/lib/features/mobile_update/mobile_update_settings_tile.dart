import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/mobile_update_strings.dart';
import 'mobile_update_models.dart';
import 'mobile_update_screen.dart';
import 'mobile_update_service.dart';

class MobileUpdateSettingsTile extends StatelessWidget {
  const MobileUpdateSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final l = MobileUpdateStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final state = context.watch<MobileUpdateService>().state;
    return ListTile(
      key: const ValueKey('settings_mobile_update_tile'),
      leading: Icon(Icons.system_update_outlined, color: cs.primary),
      title: Text(l.title),
      subtitle: Text(_subtitle(l, state)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.showSettingsBadge)
            Container(
              key: const ValueKey('settings_mobile_update_badge'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: cs.error,
                shape: BoxShape.circle,
              ),
            ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const MobileUpdateScreen()),
      ),
    );
  }

  String _subtitle(MobileUpdateStrings l, MobileUpdateState state) {
    return switch (state.phase) {
      MobileUpdatePhase.updateAvailable => l.updateAvailable,
      MobileUpdatePhase.restartRequired => l.restartRequired,
      MobileUpdatePhase.unavailable => l.unavailable,
      MobileUpdatePhase.failed => l.failure(state.failureKind),
      MobileUpdatePhase.checking => l.checking,
      MobileUpdatePhase.downloading => l.downloading,
      _ => '${l.settingsSubtitle} · ${l.channelLabel(state.channel)}',
    };
  }
}
