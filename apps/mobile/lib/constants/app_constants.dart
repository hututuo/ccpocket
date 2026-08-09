/// App-wide constants
class AppConstants {
  AppConstants._();

  /// Local Mobile/Bridge release-train revision.
  ///
  /// This replaces public npm "latest" checks for this compatibility fork.
  /// Bump it in Mobile and Bridge together only when an older counterpart
  /// should show a compatibility reminder.
  static const int clientBridgeCompatibilityRevision = 1;

  /// Maximum number of machines to keep in history
  /// Favorites are always kept, non-favorites are pruned by lastConnected
  static const int maxMachineHistory = 50;

  /// Default project path on remote machines (for SSH update commands)
  static const String defaultProjectPath = '~/Workspace/ccpocket';

  // ── External links ──

  /// Install landing page (redirects to App Store / Play Store on mobile)
  static const String installUrl = 'https://k9i-0.github.io/ccpocket/install';

  /// Primary share URL — uses install page for better mobile conversion
  static const String shareUrl = installUrl;

  /// GitHub repository URL
  static const String githubUrl = 'https://github.com/K9i-0/ccpocket';

  /// GitHub Releases filtered to macOS desktop builds
  static const String macOSReleasesUrl =
      'https://github.com/K9i-0/ccpocket/releases?q=macos';

  /// Claude API billing settings page
  static const String claudeApiBillingUrl =
      'https://platform.claude.com/settings/billing';

  /// Claude subscription usage settings page
  static const String claudeSubscriptionUsageUrl =
      'https://claude.ai/settings/usage';

  /// App Store URL (iOS)
  static const String appStoreUrl =
      'https://apps.apple.com/us/app/cc-pocket-code-anywhere/id6759188790';

  /// Play Store URL (Android)
  static const String playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.k9i.ccpocket';

  /// Public privacy policy page
  static const String privacyPolicyUrl =
      'https://github.com/K9i-0/ccpocket/blob/main/PRIVACY_POLICY.md';

  /// Public Korean privacy policy page
  static const String privacyPolicyKoUrl =
      'https://github.com/K9i-0/ccpocket/blob/main/PRIVACY_POLICY.ko.md';

  /// Apple standard EULA for auto-renewable subscriptions
  static const String termsOfUseUrl =
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';
}
