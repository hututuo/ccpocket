import 'package:ccpocket/features/session_insights/state/session_insights_quota_cache.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'serial writes keep the newest quota and expire at the bounded TTL',
    () async {
      final cache = SessionInsightsQuotaCache();
      final now = DateTime.utc(2030);

      await Future.wait([
        cache.write(
          sourceKey: 'source',
          sessionId: 'thread',
          quota: const SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: 10),
          ),
          cachedAt: now,
        ),
        cache.write(
          sourceKey: 'source',
          sessionId: 'thread',
          quota: const SessionUsageInfo(
            provider: 'codex',
            sevenDay: SessionUsageWindow(utilization: 20),
          ),
          cachedAt: now.add(const Duration(seconds: 1)),
        ),
      ]);

      final newest = await cache.read(
        sourceKey: 'source',
        sessionId: 'thread',
        now: now.add(const Duration(seconds: 1)),
        timeToLive: const Duration(minutes: 10),
      );
      expect(newest?.quota.fiveHour, isNull);
      expect(newest?.quota.sevenDay?.utilization, 20);

      final expired = await cache.read(
        sourceKey: 'source',
        sessionId: 'thread',
        now: now.add(const Duration(minutes: 11)),
        timeToLive: const Duration(minutes: 10),
      );
      expect(expired, isNull);
    },
  );

  test(
    'phone-local quota store evicts its oldest entry after 32 threads',
    () async {
      final cache = SessionInsightsQuotaCache();
      final now = DateTime.utc(2030);

      for (var index = 0; index < 33; index++) {
        await cache.write(
          sourceKey: 'bounded-source',
          sessionId: 'thread-$index',
          quota: SessionUsageInfo(
            provider: 'codex',
            fiveHour: SessionUsageWindow(utilization: index.toDouble()),
          ),
          cachedAt: now.add(Duration(seconds: index)),
        );
      }

      final evicted = await cache.read(
        sourceKey: 'bounded-source',
        sessionId: 'thread-0',
        now: now.add(const Duration(seconds: 33)),
        timeToLive: const Duration(minutes: 10),
      );
      final retained = await cache.read(
        sourceKey: 'bounded-source',
        sessionId: 'thread-32',
        now: now.add(const Duration(seconds: 33)),
        timeToLive: const Duration(minutes: 10),
      );

      expect(evicted, isNull);
      expect(retained?.quota.fiveHour?.utilization, 32);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), hasLength(1));
    },
  );
}
