// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logger.dart';
import 'mobile_update_gateway.dart';
import 'mobile_update_models.dart';

const mobileUpdateAutomaticCheckInterval = Duration(hours: 6);

abstract interface class MobileUpdateSecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class FlutterMobileUpdateSecureStore implements MobileUpdateSecureStore {
  const FlutterMobileUpdateSecureStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class MobileUpdateService extends ChangeNotifier {
  MobileUpdateService({
    required SharedPreferences preferences,
    required MobileUpdateSecureStore secureStore,
    MobileUpdateGateway? gateway,
    DateTime Function()? now,
  }) : _preferences = preferences,
       _secureStore = secureStore,
       _gateway = gateway ?? ShorebirdMobileUpdateGateway(),
       _now = now ?? DateTime.now;

  static const _modeKey = 'mobile_update_mode_v1';
  static const _lastCheckedAtKey = 'mobile_update_last_checked_at_v1';
  static const _developerUnlockedKey = 'mobile_update_developer_unlocked_v1';
  static const _channelKey = 'mobile_update_channel_v1';

  final SharedPreferences _preferences;
  final MobileUpdateSecureStore _secureStore;
  final MobileUpdateGateway _gateway;
  final DateTime Function() _now;

  MobileUpdateState _state = const MobileUpdateState();
  Future<void>? _initialization;
  Future<void>? _activeOperation;
  _MobileUpdateOperation? _retryOperation;

  MobileUpdateState get state => _state;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    final mode = _parseMode(_preferences.getString(_modeKey));
    final lastCheckedAt = DateTime.tryParse(
      _preferences.getString(_lastCheckedAtKey) ?? '',
    );
    var developerUnlocked = false;
    var channel = MobileUpdateChannel.stable;
    try {
      developerUnlocked =
          await _secureStore.read(_developerUnlockedKey) == 'true';
      if (developerUnlocked) {
        channel = _parseChannel(await _secureStore.read(_channelKey));
      }
    } catch (error) {
      logger.warning('[mobile_update] secure settings unavailable: $error');
    }

    _replaceState(
      _state.copyWith(
        mode: mode,
        channel: channel,
        developerSettingsUnlocked: developerUnlocked,
        lastCheckedAt: lastCheckedAt,
        clearFailure: true,
      ),
    );

    if (!_gateway.isAvailable) {
      _replaceState(
        _state.copyWith(
          phase: MobileUpdatePhase.unavailable,
          clearFailure: true,
        ),
      );
      return;
    }
    await _refreshPatchNumbers();
    if (_hasDownloadedPatchWaiting) {
      _replaceState(
        _state.copyWith(
          phase: MobileUpdatePhase.restartRequired,
          shouldPromptRestart: mode == MobileUpdateMode.automatic,
          clearFailure: true,
        ),
      );
    }
  }

  Future<void> runStartupPolicy() async {
    await initialize();
    if (_state.mode == MobileUpdateMode.manual || !_gateway.isAvailable) return;
    await checkInBackground();
  }

  Future<void> checkManually() async {
    await initialize();
    return _singleFlight(() => _check(allowAutomaticDownload: false));
  }

  Future<void> checkInBackground() async {
    await initialize();
    if (_state.mode == MobileUpdateMode.manual || !_gateway.isAvailable) return;
    final lastCheckedAt = _state.lastCheckedAt;
    if (lastCheckedAt != null) {
      final elapsed = _now().difference(lastCheckedAt);
      if (!elapsed.isNegative && elapsed < mobileUpdateAutomaticCheckInterval) {
        return;
      }
    }
    return _singleFlight(() => _check(allowAutomaticDownload: true));
  }

  Future<void> downloadAvailableUpdate() async {
    await initialize();
    if (_state.phase != MobileUpdatePhase.updateAvailable) return;
    return _singleFlight(
      () => _download(
        promptAfterDownload: _state.mode != MobileUpdateMode.silent,
      ),
    );
  }

  Future<void> retry() async {
    await initialize();
    if (_retryOperation == _MobileUpdateOperation.download) {
      return _singleFlight(
        () => _download(
          promptAfterDownload: _state.mode != MobileUpdateMode.silent,
        ),
      );
    }
    return checkManually();
  }

  Future<void> setMode(MobileUpdateMode mode) async {
    await initialize();
    if (_state.mode == mode) return;
    await _preferences.setString(_modeKey, mode.name);
    _replaceState(_state.copyWith(mode: mode));
    if (mode != MobileUpdateMode.manual) {
      if (_state.phase == MobileUpdatePhase.updateAvailable) {
        unawaited(downloadAvailableUpdate());
      } else {
        unawaited(checkInBackground());
      }
    }
  }

  Future<bool> unlockDeveloperSettings() async {
    await initialize();
    if (_state.developerSettingsUnlocked) return false;
    try {
      await _secureStore.write(_developerUnlockedKey, 'true');
    } catch (error) {
      logger.warning(
        '[mobile_update] failed to unlock developer settings: $error',
      );
      return false;
    }
    _replaceState(_state.copyWith(developerSettingsUnlocked: true));
    return true;
  }

  Future<bool> setChannel(MobileUpdateChannel channel) async {
    await initialize();
    if (channel == MobileUpdateChannel.owner &&
        !_state.developerSettingsUnlocked) {
      return false;
    }
    if (_state.channel == channel) return true;
    try {
      await _secureStore.write(_channelKey, channel.name);
    } catch (error) {
      logger.warning('[mobile_update] failed to store update channel: $error');
      return false;
    }
    _replaceState(
      _state.copyWith(
        channel: channel,
        phase: _hasDownloadedPatchWaiting
            ? MobileUpdatePhase.restartRequired
            : MobileUpdatePhase.idle,
        clearCheckedChannel: !_hasDownloadedPatchWaiting,
        clearTargetPatchNumber: !_hasDownloadedPatchWaiting,
        clearFailure: true,
      ),
    );
    _retryOperation = null;
    return true;
  }

  void dismissRestartPrompt() {
    if (!_state.shouldPromptRestart) return;
    _replaceState(_state.copyWith(shouldPromptRestart: false));
  }

  Future<void> _check({required bool allowAutomaticDownload}) async {
    _retryOperation = null;
    if (!_gateway.isAvailable) {
      _replaceState(
        _state.copyWith(
          phase: MobileUpdatePhase.unavailable,
          clearFailure: true,
        ),
      );
      return;
    }
    final channel = _state.channel;
    _replaceState(
      _state.copyWith(
        phase: MobileUpdatePhase.checking,
        checkedChannel: channel,
        clearFailure: true,
      ),
    );
    try {
      final result = await _gateway.check(channel);
      final checkedAt = _now();
      await _preferences.setString(
        _lastCheckedAtKey,
        checkedAt.toIso8601String(),
      );
      await _refreshPatchNumbers();
      switch (result) {
        case MobileUpdateCheckResult.upToDate:
          _replaceState(
            _state.copyWith(
              phase: MobileUpdatePhase.upToDate,
              lastCheckedAt: checkedAt,
              checkedChannel: channel,
              clearTargetPatchNumber: !_hasDownloadedPatchWaiting,
              clearFailure: true,
            ),
          );
        case MobileUpdateCheckResult.outdated:
          _replaceState(
            _state.copyWith(
              phase: MobileUpdatePhase.updateAvailable,
              lastCheckedAt: checkedAt,
              checkedChannel: channel,
              // The public Shorebird SDK does not expose the remote patch
              // number until the patch has been downloaded.
              clearTargetPatchNumber: true,
              clearFailure: true,
            ),
          );
          if (allowAutomaticDownload) {
            await _download(
              promptAfterDownload: _state.mode == MobileUpdateMode.automatic,
            );
          }
        case MobileUpdateCheckResult.restartRequired:
          _replaceState(
            _state.copyWith(
              phase: MobileUpdatePhase.restartRequired,
              lastCheckedAt: checkedAt,
              checkedChannel: channel,
              shouldPromptRestart: _state.mode == MobileUpdateMode.automatic,
              clearFailure: true,
            ),
          );
        case MobileUpdateCheckResult.unavailable:
          _replaceState(
            _state.copyWith(
              phase: MobileUpdatePhase.unavailable,
              lastCheckedAt: checkedAt,
              checkedChannel: channel,
              clearFailure: true,
            ),
          );
      }
    } catch (error) {
      _setFailure(error, retryOperation: _MobileUpdateOperation.check);
    }
  }

  Future<void> _download({required bool promptAfterDownload}) async {
    _retryOperation = null;
    final channel = _state.channel;
    _replaceState(
      _state.copyWith(
        phase: MobileUpdatePhase.downloading,
        checkedChannel: channel,
        clearFailure: true,
      ),
    );
    try {
      await _gateway.download(channel);
      await _refreshPatchNumbers();
      _replaceState(
        _state.copyWith(
          phase: MobileUpdatePhase.restartRequired,
          shouldPromptRestart: promptAfterDownload,
          clearFailure: true,
        ),
      );
    } catch (error) {
      _setFailure(error, retryOperation: _MobileUpdateOperation.download);
    }
  }

  Future<void> _refreshPatchNumbers() async {
    try {
      final current = await _gateway.readCurrentPatchNumber();
      final next = await _gateway.readNextPatchNumber();
      _replaceState(
        _state.copyWith(
          currentPatchNumber: current,
          clearCurrentPatchNumber: current == null,
          targetPatchNumber: next,
          clearTargetPatchNumber: next == null,
        ),
      );
    } catch (error) {
      logger.warning('[mobile_update] failed to read patch numbers: $error');
    }
  }

  bool get _hasDownloadedPatchWaiting {
    final next = _state.targetPatchNumber;
    final current = _state.currentPatchNumber;
    return next != null && next != current;
  }

  Future<void> _singleFlight(Future<void> Function() operation) {
    final active = _activeOperation;
    if (active != null) return active;
    late final Future<void> next;
    next = operation().whenComplete(() {
      if (identical(_activeOperation, next)) _activeOperation = null;
    });
    _activeOperation = next;
    return next;
  }

  void _setFailure(
    Object error, {
    required _MobileUpdateOperation retryOperation,
  }) {
    final mapped = error is MobileUpdateGatewayException
        ? error
        : _classifyFailure(error);
    _replaceState(
      _state.copyWith(
        phase: MobileUpdatePhase.failed,
        failureKind: mapped.kind,
        failureDetail: mapped.detail,
        shouldPromptRestart: false,
      ),
    );
    _retryOperation = retryOperation;
    logger.warning('[mobile_update] ${mapped.kind.name}: ${mapped.detail}');
  }

  MobileUpdateGatewayException _classifyFailure(Object error) {
    final detail = error.toString();
    final normalized = detail.toLowerCase();
    if (normalized.contains('signature') ||
        normalized.contains('public key') ||
        normalized.contains('verification')) {
      return MobileUpdateGatewayException(
        MobileUpdateFailureKind.signature,
        detail,
      );
    }
    if (normalized.contains('release version') ||
        normalized.contains('version mismatch') ||
        normalized.contains('base version')) {
      return MobileUpdateGatewayException(
        MobileUpdateFailureKind.versionMismatch,
        detail,
      );
    }
    if (normalized.contains('socket') ||
        normalized.contains('network') ||
        normalized.contains('connection') ||
        normalized.contains('timed out') ||
        normalized.contains('timeout')) {
      return MobileUpdateGatewayException(
        MobileUpdateFailureKind.network,
        detail,
      );
    }
    return MobileUpdateGatewayException(
      MobileUpdateFailureKind.unknown,
      detail,
    );
  }

  void _replaceState(MobileUpdateState next) {
    _state = next;
    notifyListeners();
  }

  static MobileUpdateMode _parseMode(String? value) {
    return MobileUpdateMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => MobileUpdateMode.automatic,
    );
  }

  static MobileUpdateChannel _parseChannel(String? value) {
    return MobileUpdateChannel.values.firstWhere(
      (channel) => channel.name == value,
      orElse: () => MobileUpdateChannel.stable,
    );
  }
}

enum _MobileUpdateOperation { check, download }
