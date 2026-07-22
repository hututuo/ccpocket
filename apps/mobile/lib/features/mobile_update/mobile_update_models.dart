import 'package:flutter/foundation.dart';

enum MobileUpdateMode { automatic, silent, manual }

enum MobileUpdateChannel { stable, owner }

enum MobileUpdatePhase {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  restartRequired,
  unavailable,
  failed,
}

enum MobileUpdateFailureKind {
  network,
  signature,
  versionMismatch,
  download,
  install,
  unknown,
}

enum MobileUpdateCheckResult {
  upToDate,
  outdated,
  restartRequired,
  unavailable,
}

@immutable
class MobileUpdateState {
  const MobileUpdateState({
    this.phase = MobileUpdatePhase.idle,
    this.mode = MobileUpdateMode.automatic,
    this.channel = MobileUpdateChannel.stable,
    this.developerSettingsUnlocked = false,
    this.lastCheckedAt,
    this.checkedChannel,
    this.currentPatchNumber,
    this.targetPatchNumber,
    this.failureKind,
    this.failureDetail,
    this.shouldPromptRestart = false,
  });

  final MobileUpdatePhase phase;
  final MobileUpdateMode mode;
  final MobileUpdateChannel channel;
  final bool developerSettingsUnlocked;
  final DateTime? lastCheckedAt;
  final MobileUpdateChannel? checkedChannel;
  final int? currentPatchNumber;
  final int? targetPatchNumber;
  final MobileUpdateFailureKind? failureKind;
  final String? failureDetail;
  final bool shouldPromptRestart;

  bool get isBusy =>
      phase == MobileUpdatePhase.checking ||
      phase == MobileUpdatePhase.downloading;

  bool get showSettingsBadge =>
      phase == MobileUpdatePhase.updateAvailable ||
      phase == MobileUpdatePhase.restartRequired;

  MobileUpdateState copyWith({
    MobileUpdatePhase? phase,
    MobileUpdateMode? mode,
    MobileUpdateChannel? channel,
    bool? developerSettingsUnlocked,
    DateTime? lastCheckedAt,
    bool clearLastCheckedAt = false,
    MobileUpdateChannel? checkedChannel,
    bool clearCheckedChannel = false,
    int? currentPatchNumber,
    bool clearCurrentPatchNumber = false,
    int? targetPatchNumber,
    bool clearTargetPatchNumber = false,
    MobileUpdateFailureKind? failureKind,
    bool clearFailure = false,
    String? failureDetail,
    bool? shouldPromptRestart,
  }) {
    return MobileUpdateState(
      phase: phase ?? this.phase,
      mode: mode ?? this.mode,
      channel: channel ?? this.channel,
      developerSettingsUnlocked:
          developerSettingsUnlocked ?? this.developerSettingsUnlocked,
      lastCheckedAt: clearLastCheckedAt
          ? null
          : (lastCheckedAt ?? this.lastCheckedAt),
      checkedChannel: clearCheckedChannel
          ? null
          : (checkedChannel ?? this.checkedChannel),
      currentPatchNumber: clearCurrentPatchNumber
          ? null
          : (currentPatchNumber ?? this.currentPatchNumber),
      targetPatchNumber: clearTargetPatchNumber
          ? null
          : (targetPatchNumber ?? this.targetPatchNumber),
      failureKind: clearFailure ? null : (failureKind ?? this.failureKind),
      failureDetail: clearFailure
          ? null
          : (failureDetail ?? this.failureDetail),
      shouldPromptRestart: shouldPromptRestart ?? this.shouldPromptRestart,
    );
  }
}

class MobileUpdateGatewayException implements Exception {
  const MobileUpdateGatewayException(this.kind, this.detail);

  final MobileUpdateFailureKind kind;
  final String detail;

  @override
  String toString() => detail;
}
