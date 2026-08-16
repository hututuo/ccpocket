import 'package:flutter/material.dart';

import '../../../constants/app_constants.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/machine.dart';

/// Banner shown when the locally distributed IPA and Bridge do not match.
///
/// Follows the same pattern as [SessionReconnectBanner] but with an update icon
/// and a dismiss button.
class BridgeUpdateBanner extends StatelessWidget {
  final String currentVersion;
  final int? bridgeCompatibilityRevision;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  const BridgeUpdateBanner({
    super.key,
    required this.currentVersion,
    required this.bridgeCompatibilityRevision,
    this.onTap,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = colorScheme.tertiary;
    final l = AppLocalizations.of(context);
    final compatibility = compareClientBridgeCompatibility(
      bridgeRevision: bridgeCompatibilityRevision,
      mobileRevision: AppConstants.clientBridgeCompatibilityRevision,
    );
    final message = switch (compatibility) {
      ClientBridgeCompatibility.bridgeOlder => l.clientBridgeBridgeOlder,
      ClientBridgeCompatibility.mobileOlder => l.clientBridgeMobileOlder,
      ClientBridgeCompatibility.matched => l.clientBridgeMatched,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: const ValueKey('bridge_update_banner'),
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(
                  compatibility == ClientBridgeCompatibility.mobileOlder
                      ? Icons.phone_iphone
                      : Icons.system_update,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$message · ${l.clientBridgeCompatibilityDetail(currentVersion)}',
                    style: TextStyle(fontSize: 13, color: color),
                  ),
                ),
                if (onDismiss != null)
                  GestureDetector(
                    key: const ValueKey('bridge_update_banner_dismiss'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onDismiss,
                    child: Icon(Icons.close, size: 16, color: color),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Returns true if the banner should be shown.
  static bool shouldShow(
    String? currentVersion, {
    required int? bridgeCompatibilityRevision,
  }) {
    if (currentVersion == null) return false;
    return compareClientBridgeCompatibility(
          bridgeRevision: bridgeCompatibilityRevision,
          mobileRevision: AppConstants.clientBridgeCompatibilityRevision,
        ) !=
        ClientBridgeCompatibility.matched;
  }
}
