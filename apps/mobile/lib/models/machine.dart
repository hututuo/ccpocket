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

  /// The endpoint answered, but its signed Bridge identity no longer matches
  /// the identity previously pinned to this route.
  ///
  /// This is intentionally distinct from [offline]: connecting would risk
  /// opening a different computer through a reused IP or DNS name.
  identityChanged,
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

    /// Stable cryptographic installation identity advertised by a modern
    /// Bridge before WebSocket authentication.
    ///
    /// The value is derived from a Bridge-owned signing key. It is not a Mac
    /// serial number, MAC address, or other hardware identifier.
    String? bridgeIdentityId,

    /// Base64url-encoded Ed25519 public key used to pin [bridgeIdentityId].
    String? bridgeIdentityPublicKey,

    /// Computer name signed by the Bridge identity document.
    String? bridgeComputerName,

    /// Last advertised authentication mode (`key`, `paired_or_key`, `open`).
    String? bridgeAuthMode,

    /// Last time this route produced a valid signed identity document.
    DateTime? bridgeIdentityVerifiedAt,

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

    /// Round-trip time of the latest successful HTTP health probe.
    int? latencyMs,

    /// Bridge version info (fetched during health check)
    BridgeVersionInfo? versionInfo,
  }) = _MachineWithStatus;

  /// Check if the machine needs a Bridge update
  bool needsUpdate(String expectedVersion) {
    if (versionInfo == null) return false;
    return versionInfo!.needsUpdate(expectedVersion);
  }
}

/// One user-visible computer with one or more transport routes.
///
/// Existing [Machine] records remain the durable route model so their API
/// keys, SSH credentials and tunnel configuration keep independent lifetimes.
/// This projection only groups routes after Bridge identity has been proven.
class BridgeMachineGroup {
  const BridgeMachineGroup({
    required this.id,
    required this.routes,
    this.bridgeIdentityId,
    this.bridgeInstanceId,
    this.computerName,
  });

  final String id;
  final List<MachineWithStatus> routes;
  final String? bridgeIdentityId;
  final String? bridgeInstanceId;
  final String? computerName;

  MachineWithStatus get preferredRoute {
    final online = routes
        .where((route) => route.status == MachineStatus.online)
        .toList(growable: false);
    final candidates = online.isEmpty ? routes : online;
    final sorted = List<MachineWithStatus>.of(candidates)
      ..sort(_comparePreferredRoutes);
    return sorted.first;
  }

  bool get hasOnlineRoute =>
      routes.any((route) => route.status == MachineStatus.online);

  bool get hasIdentityConflict =>
      routes.any((route) => route.status == MachineStatus.identityChanged);

  bool get isFavorite => routes.any((route) => route.machine.isFavorite);

  String get displayName {
    final explicitNames = routes
        .map((route) => route.machine.name?.trim())
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .toSet();
    if (explicitNames.length == 1) return explicitNames.single;
    final signedName = computerName?.trim();
    if (signedName != null && signedName.isNotEmpty) return signedName;
    if (explicitNames.isNotEmpty) return explicitNames.first;
    return preferredRoute.machine.displayName;
  }

  DateTime? get lastConnected {
    DateTime? result;
    for (final route in routes) {
      final candidate = route.machine.lastConnected;
      if (candidate != null && (result == null || candidate.isAfter(result))) {
        result = candidate;
      }
    }
    return result;
  }

  MachineStatus get status {
    if (hasIdentityConflict) return MachineStatus.identityChanged;
    if (hasOnlineRoute) return MachineStatus.online;
    if (routes.any((route) => route.status == MachineStatus.unknown)) {
      return MachineStatus.unknown;
    }
    if (routes.any((route) => route.status == MachineStatus.unreachable)) {
      return MachineStatus.unreachable;
    }
    return MachineStatus.offline;
  }

  static int _comparePreferredRoutes(
    MachineWithStatus left,
    MachineWithStatus right,
  ) {
    final leftLatency = left.latencyMs;
    final rightLatency = right.latencyMs;
    if (leftLatency != null || rightLatency != null) {
      if (leftLatency == null) return 1;
      if (rightLatency == null) return -1;
      final latencyOrder = leftLatency.compareTo(rightLatency);
      if (latencyOrder != 0) return latencyOrder;
    }
    final leftConnected =
        left.machine.lastConnected?.millisecondsSinceEpoch ?? 0;
    final rightConnected =
        right.machine.lastConnected?.millisecondsSinceEpoch ?? 0;
    final recencyOrder = rightConnected.compareTo(leftConnected);
    if (recencyOrder != 0) return recencyOrder;
    return left.machine.uniqueKey.compareTo(right.machine.uniqueKey);
  }
}

/// Groups saved connection routes by proven Bridge identity.
///
/// Signed identity wins. Older authenticated Bridges fall back to their
/// existing random [Machine.bridgeInstanceId]. Unproven legacy endpoints stay
/// isolated so a reused IP can never merge caches from two computers.
List<BridgeMachineGroup> groupBridgeMachineRoutes(
  Iterable<MachineWithStatus> routes,
) {
  final grouped = <String, List<MachineWithStatus>>{};
  for (final route in routes) {
    final machine = route.machine;
    final signedId = machine.bridgeIdentityId?.trim();
    final legacyId = machine.bridgeInstanceId?.trim();
    final key = signedId != null && signedId.isNotEmpty
        ? 'signed:$signedId'
        : legacyId != null && legacyId.isNotEmpty
        ? 'legacy:$legacyId'
        : 'route:${machine.id}';
    grouped.putIfAbsent(key, () => []).add(route);
  }

  final result = grouped.entries.map((entry) {
    final groupRoutes = List<MachineWithStatus>.of(entry.value);
    final first = groupRoutes.first.machine;
    final signedId = first.bridgeIdentityId?.trim();
    final legacyId = first.bridgeInstanceId?.trim();
    final computerNames = groupRoutes
        .map((route) => route.machine.bridgeComputerName?.trim())
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .toSet();
    return BridgeMachineGroup(
      id: entry.key,
      routes: groupRoutes,
      bridgeIdentityId: signedId?.isEmpty == true ? null : signedId,
      bridgeInstanceId: legacyId?.isEmpty == true ? null : legacyId,
      computerName: computerNames.length == 1 ? computerNames.single : null,
    );
  }).toList();

  result.sort((left, right) {
    if (left.isFavorite != right.isFavorite) {
      return left.isFavorite ? -1 : 1;
    }
    final leftTime = left.lastConnected?.millisecondsSinceEpoch ?? 0;
    final rightTime = right.lastConnected?.millisecondsSinceEpoch ?? 0;
    final recency = rightTime.compareTo(leftTime);
    if (recency != 0) return recency;
    return left.displayName.compareTo(right.displayName);
  });
  return result;
}
