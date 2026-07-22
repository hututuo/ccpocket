import 'dart:async';

import 'package:ccpocket/features/mobile_update/mobile_update_gateway.dart';
import 'package:ccpocket/features/mobile_update/mobile_update_models.dart';
import 'package:ccpocket/features/mobile_update/mobile_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2026, 7, 22, 8);
    SharedPreferences.setMockInitialValues({});
  });

  Future<MobileUpdateService> createService({
    _FakeGateway? gateway,
    _MemorySecureStore? secureStore,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    return MobileUpdateService(
      preferences: prefs,
      secureStore: secureStore ?? _MemorySecureStore(),
      gateway: gateway ?? _FakeGateway(),
      now: () => now,
    );
  }

  test('manual check bypasses the six-hour automatic throttle', () async {
    SharedPreferences.setMockInitialValues({
      'mobile_update_last_checked_at_v1': now
          .subtract(const Duration(minutes: 5))
          .toIso8601String(),
    });
    final gateway = _FakeGateway();
    final service = await createService(gateway: gateway);

    await service.checkInBackground();
    expect(gateway.checkCalls, 0);

    await service.checkManually();
    expect(gateway.checkCalls, 1);
    expect(service.state.phase, MobileUpdatePhase.upToDate);
  });

  test('manual check reports an update without downloading it', () async {
    final gateway = _FakeGateway(
      result: MobileUpdateCheckResult.outdated,
      currentPatch: 2,
      nextPatch: 2,
    );
    final service = await createService(gateway: gateway);

    await service.checkManually();

    expect(gateway.checkCalls, 1);
    expect(gateway.downloadCalls, 0);
    expect(service.state.phase, MobileUpdatePhase.updateAvailable);
    expect(service.state.checkedChannel, MobileUpdateChannel.stable);
    expect(service.state.targetPatchNumber, isNull);
  });

  test('concurrent checks share one network operation', () async {
    final completer = Completer<MobileUpdateCheckResult>();
    final gateway = _FakeGateway(checkCompleter: completer);
    final service = await createService(gateway: gateway);

    final first = service.checkManually();
    final second = service.checkManually();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.checkCalls, 1);

    completer.complete(MobileUpdateCheckResult.upToDate);
    await Future.wait([first, second]);
    expect(gateway.checkCalls, 1);
  });

  test(
    'automatic mode downloads in background and requests a prompt',
    () async {
      final gateway = _FakeGateway(
        result: MobileUpdateCheckResult.outdated,
        nextPatchAfterDownload: 8,
      );
      final service = await createService(gateway: gateway);

      await service.checkInBackground();

      expect(gateway.downloadCalls, 1);
      expect(service.state.phase, MobileUpdatePhase.restartRequired);
      expect(service.state.targetPatchNumber, 8);
      expect(service.state.shouldPromptRestart, isTrue);
    },
  );

  test('silent mode downloads without requesting a prompt', () async {
    final gateway = _FakeGateway(
      result: MobileUpdateCheckResult.outdated,
      nextPatchAfterDownload: 3,
    );
    final service = await createService(gateway: gateway);
    await service.setMode(MobileUpdateMode.silent);
    await service.checkManually();
    gateway.checkCalls = 0;
    gateway.downloadCalls = 0;

    now = now.add(const Duration(hours: 7));
    await service.checkInBackground();

    expect(gateway.downloadCalls, 1);
    expect(service.state.phase, MobileUpdatePhase.restartRequired);
    expect(service.state.shouldPromptRestart, isFalse);
  });

  test('manual mode disables background checks', () async {
    final gateway = _FakeGateway(result: MobileUpdateCheckResult.outdated);
    final service = await createService(gateway: gateway);
    await service.setMode(MobileUpdateMode.manual);

    await service.checkInBackground();

    expect(gateway.checkCalls, 0);
    expect(gateway.downloadCalls, 0);
  });

  test(
    'switching to automatic downloads an already discovered update',
    () async {
      final gateway = _FakeGateway(
        result: MobileUpdateCheckResult.outdated,
        nextPatchAfterDownload: 6,
      );
      final service = await createService(gateway: gateway);
      await service.setMode(MobileUpdateMode.manual);
      await service.checkManually();

      await service.setMode(MobileUpdateMode.automatic);
      await Future<void>.delayed(Duration.zero);

      expect(gateway.downloadCalls, 1);
      expect(service.state.phase, MobileUpdatePhase.restartRequired);
      expect(service.state.targetPatchNumber, 6);
    },
  );

  test(
    'owner channel requires local developer unlock and is persisted',
    () async {
      final gateway = _FakeGateway();
      final secureStore = _MemorySecureStore();
      final service = await createService(
        gateway: gateway,
        secureStore: secureStore,
      );

      expect(await service.setChannel(MobileUpdateChannel.owner), isFalse);
      expect(await service.unlockDeveloperSettings(), isTrue);
      expect(await service.setChannel(MobileUpdateChannel.owner), isTrue);
      await service.checkManually();

      expect(gateway.lastCheckedChannel, MobileUpdateChannel.owner);
      expect(secureStore.values['mobile_update_channel_v1'], 'owner');
    },
  );

  test('switching back to stable does not pretend to downgrade', () async {
    final gateway = _FakeGateway(currentPatch: 9, nextPatch: 9);
    final secureStore = _MemorySecureStore({
      'mobile_update_developer_unlocked_v1': 'true',
      'mobile_update_channel_v1': 'owner',
    });
    final service = await createService(
      gateway: gateway,
      secureStore: secureStore,
    );
    await service.initialize();

    await service.setChannel(MobileUpdateChannel.stable);

    expect(service.state.currentPatchNumber, 9);
    expect(service.state.channel, MobileUpdateChannel.stable);
    expect(service.state.phase, MobileUpdatePhase.idle);
  });

  test('download failure is exposed and retry remains possible', () async {
    final gateway = _FakeGateway(
      result: MobileUpdateCheckResult.outdated,
      downloadError: const MobileUpdateGatewayException(
        MobileUpdateFailureKind.download,
        'download interrupted',
      ),
    );
    final service = await createService(gateway: gateway);
    await service.checkManually();

    await service.downloadAvailableUpdate();

    expect(service.state.phase, MobileUpdatePhase.failed);
    expect(service.state.failureKind, MobileUpdateFailureKind.download);
    gateway.downloadError = null;
    await service.retry();
    expect(gateway.downloadCalls, 2);
    expect(service.state.phase, MobileUpdatePhase.restartRequired);
  });

  test('network errors are classified for the UI', () async {
    final gateway = _FakeGateway(checkError: Exception('Socket timeout'));
    final service = await createService(gateway: gateway);

    await service.checkManually();

    expect(service.state.phase, MobileUpdatePhase.failed);
    expect(service.state.failureKind, MobileUpdateFailureKind.network);
  });

  test('signature and base-version failures remain distinguishable', () async {
    final gateway = _FakeGateway(
      checkError: Exception('Patch signature verification failed'),
    );
    final service = await createService(gateway: gateway);

    await service.checkManually();
    expect(service.state.failureKind, MobileUpdateFailureKind.signature);

    gateway.checkError = Exception('Release version mismatch for base version');
    await service.checkManually();
    expect(service.state.failureKind, MobileUpdateFailureKind.versionMismatch);
  });

  test('a downloaded patch is detected during initialization', () async {
    final gateway = _FakeGateway(currentPatch: 2, nextPatch: 4);
    final service = await createService(gateway: gateway);

    await service.initialize();

    expect(service.state.phase, MobileUpdatePhase.restartRequired);
    expect(service.state.currentPatchNumber, 2);
    expect(service.state.targetPatchNumber, 4);
  });

  test('up-to-date check refreshes a server rollback patch number', () async {
    final gateway = _FakeGateway(currentPatch: 7, nextPatch: 7);
    final service = await createService(gateway: gateway);
    await service.initialize();
    gateway.currentPatch = 5;
    gateway.nextPatch = 5;

    await service.checkManually();

    expect(service.state.phase, MobileUpdatePhase.upToDate);
    expect(service.state.currentPatchNumber, 5);
  });

  test('non-Shorebird base builds require a new base IPA', () async {
    final service = await createService(
      gateway: _FakeGateway(available: false),
    );

    await service.checkManually();

    expect(service.state.phase, MobileUpdatePhase.unavailable);
  });
}

class _MemorySecureStore implements MobileUpdateSecureStore {
  _MemorySecureStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _FakeGateway implements MobileUpdateGateway {
  _FakeGateway({
    this.available = true,
    this.result = MobileUpdateCheckResult.upToDate,
    this.currentPatch,
    this.nextPatch,
    this.nextPatchAfterDownload,
    this.checkError,
    this.downloadError,
    this.checkCompleter,
  });

  final bool available;
  MobileUpdateCheckResult result;
  int? currentPatch;
  int? nextPatch;
  final int? nextPatchAfterDownload;
  Object? checkError;
  Object? downloadError;
  final Completer<MobileUpdateCheckResult>? checkCompleter;
  int checkCalls = 0;
  int downloadCalls = 0;
  MobileUpdateChannel? lastCheckedChannel;

  @override
  bool get isAvailable => available;

  @override
  Future<MobileUpdateCheckResult> check(MobileUpdateChannel channel) async {
    checkCalls++;
    lastCheckedChannel = channel;
    if (checkError case final error?) throw error;
    if (checkCompleter case final completer?) return completer.future;
    return result;
  }

  @override
  Future<void> download(MobileUpdateChannel channel) async {
    downloadCalls++;
    if (downloadError case final error?) throw error;
    nextPatch = nextPatchAfterDownload ?? nextPatch;
  }

  @override
  Future<int?> readCurrentPatchNumber() async => currentPatch;

  @override
  Future<int?> readNextPatchNumber() async => nextPatch;
}
