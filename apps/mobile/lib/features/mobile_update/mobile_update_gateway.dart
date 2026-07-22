import 'package:shorebird_code_push/shorebird_code_push.dart';

import 'mobile_update_models.dart';

abstract interface class MobileUpdateGateway {
  bool get isAvailable;

  Future<MobileUpdateCheckResult> check(MobileUpdateChannel channel);

  Future<void> download(MobileUpdateChannel channel);

  Future<int?> readCurrentPatchNumber();

  Future<int?> readNextPatchNumber();
}

class ShorebirdMobileUpdateGateway implements MobileUpdateGateway {
  ShorebirdMobileUpdateGateway({ShorebirdUpdater? updater})
    : _updater = updater ?? ShorebirdUpdater();

  final ShorebirdUpdater _updater;

  @override
  bool get isAvailable => _updater.isAvailable;

  @override
  Future<MobileUpdateCheckResult> check(MobileUpdateChannel channel) async {
    final status = await _updater.checkForUpdate(track: _track(channel));
    return switch (status) {
      UpdateStatus.upToDate => MobileUpdateCheckResult.upToDate,
      UpdateStatus.outdated => MobileUpdateCheckResult.outdated,
      UpdateStatus.restartRequired => MobileUpdateCheckResult.restartRequired,
      UpdateStatus.unavailable => MobileUpdateCheckResult.unavailable,
    };
  }

  @override
  Future<void> download(MobileUpdateChannel channel) async {
    try {
      await _updater.update(track: _track(channel));
    } on UpdateException catch (error) {
      throw MobileUpdateGatewayException(switch (error.reason) {
        UpdateFailureReason.downloadFailed => MobileUpdateFailureKind.download,
        UpdateFailureReason.installFailed => MobileUpdateFailureKind.install,
        UpdateFailureReason.noUpdate ||
        UpdateFailureReason.unknown => MobileUpdateFailureKind.unknown,
      }, error.message);
    }
  }

  @override
  Future<int?> readCurrentPatchNumber() async {
    return (await _updater.readCurrentPatch())?.number;
  }

  @override
  Future<int?> readNextPatchNumber() async {
    return (await _updater.readNextPatch())?.number;
  }

  UpdateTrack _track(MobileUpdateChannel channel) {
    return UpdateTrack(channel.name);
  }
}
