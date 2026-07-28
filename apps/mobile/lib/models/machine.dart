import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/network_endpoint.dart';

part 'machine.freezed.dart';
part 'machine.g.dart';

/// Compare the three-component compatibility core of semantic versions.
///
/// Local Bridge builds append a suffix such as `-compat.3`. They still carry
/// the complete official core version and must not be offered a destructive
/// "update" to that same official release. A genuinely newer official core
/// (for example 1.67.5 versus 1.67.4-compat.3) still wins normally.
///
/// Returns a negative value when [left] is older than [right], zero when they
/// are equal, and a positive value when [left] is newer than [right].
int compareSemanticVersions(String left, String right) {
  final parts1 = _semanticVersionCore(left);
  final parts2 = _semanticVersionCore(right);

  for (var i = 0; i < 3; i++) {
    final p1 = i < parts1.length ? (parts1[i] ?? 0) : 0;
    final p2 = i < parts2.length ? (parts2[i] ?? 0) : 0;
    if (p1 != p2) return p1 - p2;
  }
  return 0;
}

List<int?> _semanticVersionCore(String version) {
  // Narrowly recognize this fork's additive build suffix. Other prerelease
  // labels retain the official app's existing conservative comparison.
  final officialCore = version.replaceFirst(RegExp(r'-compat\.\d+$'), '');
  return officialCore.split('.').map(int.tryParse).toList();
}

/// Status of a machine's Bridge Server
enum MachineStatus {
  /// Not checked yet
  unknown,

  /// Health check passed (Bridge Server running)
  online,

  /// Health check failed (Bridge Server not running)
  offline,

  /// Network unreachable or connection refused
  unreachable,
}

/// SSH authentication type
enum SshAuthType {
  /// Password authentication
  password,

  /// Private key authentication
  privateKey,
}

/// Bridge Server version information from /version endpoint
@freezed
abstract class BridgeVersionInfo with _$BridgeVersionInfo {
  const BridgeVersionInfo._();

  const factory BridgeVersionInfo({
    required String version,
    String? nodeVersion,
    String? platform,
    String? arch,
    String? gitCommit,
    String? gitBranch,
  }) = _BridgeVersionInfo;

  factory BridgeVersionInfo.fromJson(Map<String, dynamic> json) =>
      _$BridgeVersionInfoFromJson(json);

  /// Compare versions (simple semver comparison)
  /// Returns: negative if this is older, 0 if equal, positive if this is newer
  int compareTo(String otherVersion) =>
      compareSemanticVersions(version, otherVersion);

  /// Check if update is needed (this version is older than expected)
  bool needsUpdate(String expectedVersion) => compareTo(expectedVersion) < 0;
}

/// Unified machine model combining saved machines and recent connections.
///
/// Key features:
/// - name is optional (defaults to host:port display)
/// - lastConnected for recency sorting
/// - isFavorite for pinning important machines
/// - host:port identifies one connection route
/// - bridgeInstanceId links multiple routes to one authenticated Bridge
@freezed
abstract class Machine with _$Machine {
  const Machine._();

  const factory Machine({
    /// Unique identifier (UUID)
    required String id,

    /// User-friendly display name (optional - shows host:port if null)
    String? name,

    /// IP address or hostname (typically Tailscale IP like 100.64.x.x)
    required String host,

    /// Bridge Server port
    @Default(8765) int port,

    /// Whether to connect via secure WebSocket/HTTP
    @Default(false) bool useSsl,

    /// Whether API key is stored in secure storage
    @Default(false) bool hasApiKey,

    /// Stable installation identity reported by the authenticated Bridge.
    ///
    /// This is a cache/data-source hint, not a credential. Different LAN,
    /// Tailscale, DNS, or tunnel routes may legitimately share this value.
    String? bridgeInstanceId,

    /// Last authoritative Codex Home identity observed on this route.
    ///
    /// A single Bridge installation may be restarted against another
    /// CODEX_HOME, so cache reuse is scoped by both identities.
    String? codexSourceId,

    /// Last successful connection time
    DateTime? lastConnected,

    /// Whether this machine is pinned/favorited (shows at top)
    @Default(false) bool isFavorite,

    // ---- SSH Configuration ----

    /// Whether SSH remote startup is enabled
    @Default(false) bool sshEnabled,

    /// SSH username
    String? sshUsername,

    /// SSH port
    @Default(22) int sshPort,

    /// SSH authentication type
    @Default(SshAuthType.password) SshAuthType sshAuthType,

    /// Optional SSH jump host used to reach the target SSH server
    String? sshJumpHost,

    /// SSH jump host port
    @Default(22) int sshJumpPort,

    /// Optional SSH jump username. Defaults to [sshUsername] when omitted.
    String? sshJumpUsername,

    /// SSH authentication type for the jump host when separate credentials are saved.
    @Default(SshAuthType.password) SshAuthType sshJumpAuthType,

    /// Whether SSH credentials are saved (password or private key in secure storage)
    @Default(false) bool hasCredentials,

    /// Whether separate SSH jump host credentials are saved in secure storage.
    @Default(false) bool hasJumpCredentials,
  }) = _Machine;

  factory Machine.fromJson(Map<String, dynamic> json) =>
      _$MachineFromJson(json);

  /// Display name (name if set, otherwise host:port)
  String get displayName => name ?? formatHostPort(host, port);

  /// WebSocket URL for this machine
  String get wsUrl =>
      formatUriOrigin(scheme: useSsl ? 'wss' : 'ws', host: host, port: port);

  /// HTTP base URL for health checks
  String get httpUrl => formatUriOrigin(
    scheme: useSsl ? 'https' : 'http',
    host: host,
    port: port,
  );

  /// Unique key for deduplication (host:port)
  String get uniqueKey => endpointIdentityKey(host, port);

  /// Whether this machine can be started remotely (SSH configured)
  bool get canStartRemotely => sshEnabled && sshUsername != null;
}

/// Runtime state wrapper for Machine with status and version information.
/// This is used in the UI layer to track connection status without modifying the persisted model.
@freezed
abstract class MachineWithStatus with _$MachineWithStatus {
  const MachineWithStatus._();

  const factory MachineWithStatus({
    required Machine machine,
    @Default(MachineStatus.unknown) MachineStatus status,
    DateTime? lastChecked,
    String? lastError,

    /// Bridge version info (fetched during health check)
    BridgeVersionInfo? versionInfo,
  }) = _MachineWithStatus;

  /// Check if the machine needs a Bridge update
  bool needsUpdate(String expectedVersion) {
    if (versionInfo == null) return false;
    return versionInfo!.needsUpdate(expectedVersion);
  }
}
