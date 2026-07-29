import 'dart:io';

import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('benchmarks the persistent session sync cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ccpocket_session_sync_benchmark_',
    );
    final database = SessionCatalogCacheDatabase(
      databasePath: path.join(directory.path, 'benchmark.db'),
      openDatabase: (databasePath, options) =>
          databaseFactoryFfi.openDatabase(databasePath, options: options),
    );
    final repository = SessionCatalogCacheRepository(database);
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'benchmark-bridge',
      codexSourceId: 'benchmark-source',
      websocketUrl: 'wss://benchmark.invalid/ws',
    );
    try {
      final catalog = List.generate(1500, _session);
      final catalogWrite = Stopwatch()..start();
      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(sessions: catalog, catalogRevision: 1),
      );
      catalogWrite.stop();

      final catalogLoads = <int>[];
      for (var iteration = 0; iteration < 50; iteration++) {
        final stopwatch = Stopwatch()..start();
        final snapshot = await repository.load(target);
        stopwatch.stop();
        expect(snapshot?.sessions, hasLength(1500));
        catalogLoads.add(stopwatch.elapsedMicroseconds);
      }

      final hotEntries = List.generate(
        200,
        (index) => ConversationContentWireEntry(
          entryId: 'hot-entry-$index',
          index: index,
          contentHash: 'hot-hash-$index',
          rawMessage: {
            'type': 'status',
            'status': index.isEven ? 'running' : 'idle',
          },
        ),
      );
      await repository.replaceConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'hot-thread',
        revision: 'hot-revision',
        entries: hotEntries,
        hasEarlier: true,
        turnsNextCursor: 'older-turns',
        sourceEntryCount: 2_000,
      );

      final openSamples = <int>[];
      ConversationHotWindowSnapshot? hotWindow;
      for (var iteration = 0; iteration < 100; iteration++) {
        final stopwatch = Stopwatch()..start();
        hotWindow = await repository.loadConversationWindow(
          target: target,
          provider: 'codex',
          providerSessionId: 'hot-thread',
        );
        stopwatch.stop();
        expect(hotWindow?.entries, hasLength(200));
        openSamples.add(stopwatch.elapsedMicroseconds);
      }

      final rssBeforeStage = ProcessInfo.currentRss;
      var peakRss = rssBeforeStage;
      const pageCount = 100;
      const entriesPerPage = 20;
      final stageWrite = Stopwatch()..start();
      for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
        final entries = List.generate(entriesPerPage, (localIndex) {
          final entryIndex = pageIndex * entriesPerPage + localIndex;
          return ConversationContentWireEntry(
            entryId: 'stage-entry-$entryIndex',
            index: entryIndex,
            contentHash: 'stage-hash-$entryIndex',
            rawMessage: {
              'type': 'status',
              'status': entryIndex.isEven ? 'running' : 'idle',
            },
          );
        });
        final result = await repository.stageConversationTimelinePage(
          target: target,
          subscriptionId: 'benchmark-subscription',
          provider: 'codex',
          providerSessionId: 'stage-thread',
          revision: 'stage-revision',
          baseRevision: null,
          mode: 'snapshot',
          pageIndex: pageIndex,
          pageCount: pageCount,
          entries: entries,
          deletes: const [],
          hasEarlier: true,
          turnsNextCursor: 'stage-cursor',
          sourceEntryCount: pageCount * entriesPerPage,
        );
        expect(result.pageStored, isTrue);
        expect(result.windowCommitted, pageIndex == pageCount - 1);
        final rss = ProcessInfo.currentRss;
        if (rss > peakRss) peakRss = rss;
      }
      stageWrite.stop();

      final db = await database.database;
      final queryPlan = await db.rawQuery(
        '''
        EXPLAIN QUERY PLAN
        SELECT message_json
        FROM ${SessionCatalogCacheDatabase.hotEntriesTable}
        WHERE partition_id = ?
          AND provider = ?
          AND provider_session_id = ?
        ORDER BY entry_index
        ''',
        [hotWindow!.partitionId, 'codex', 'hot-thread'],
      );
      final stagedRows = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM '
          '${SessionCatalogCacheDatabase.timelineStagesTable}',
        ),
      );
      expect(stagedRows, 0);

      catalogLoads.sort();
      openSamples.sort();
      final databaseFile = File(await database.resolvedPath);
      final output = {
        'catalogEntries': 1500,
        'catalogWriteMs': catalogWrite.elapsedMicroseconds / 1000,
        'catalogLoadP50Ms': _percentile(catalogLoads, 0.50) / 1000,
        'catalogLoadP95Ms': _percentile(catalogLoads, 0.95) / 1000,
        'hotWindowEntries': 200,
        'hotWindowOpenP50Ms': _percentile(openSamples, 0.50) / 1000,
        'hotWindowOpenP95Ms': _percentile(openSamples, 0.95) / 1000,
        'stagedEntries': pageCount * entriesPerPage,
        'stagingWriteMs': stageWrite.elapsedMicroseconds / 1000,
        'stagingPeakRssDeltaMiB': (peakRss - rssBeforeStage) / (1024 * 1024),
        'databaseMiB': await databaseFile.length() / (1024 * 1024),
        'queryPlan': queryPlan,
      };
      // ignore: avoid_print
      print('CCPOCKET_SESSION_SYNC_BENCHMARK=$output');
      expect(_percentile(openSamples, 0.95), lessThan(100 * 1000));
    } finally {
      await repository.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });
}

int _percentile(List<int> sortedSamples, double quantile) {
  final index = (sortedSamples.length * quantile).ceil() - 1;
  return sortedSamples[index.clamp(0, sortedSamples.length - 1)];
}

RecentSession _session(int index) {
  final timestamp = DateTime.utc(
    2026,
    7,
    30,
  ).subtract(Duration(minutes: index)).toIso8601String();
  return RecentSession(
    sessionId: 'thread-$index',
    provider: Provider.codex.value,
    rawPermissionMode: 'default',
    name: 'Conversation $index',
    summary: 'Summary $index',
    firstPrompt: 'Prompt $index',
    lastPrompt: 'Last prompt $index',
    created: timestamp,
    modified: timestamp,
    gitBranch: 'main',
    projectPath: '/benchmark/project-${index % 25}',
    resumeCwd: '/benchmark/project-${index % 25}',
    isSidechain: false,
    codexApprovalPolicy: CodexApprovalPolicy.onRequest.value,
    codexApprovalsReviewer: 'user',
    codexPermissionsMode: CodexPermissionsMode.defaultPermissions.value,
    executionMode: ExecutionMode.defaultMode.value,
    codexSandboxMode: 'workspace-write',
    codexModel: 'gpt-5.3-codex',
    codexProfile: 'default',
    codexModelReasoningEffort: 'high',
    codexServiceTier: 'fast',
    codexNetworkAccessEnabled: true,
    codexWebSearchMode: 'live',
    codexAdditionalWritableRoots: const [],
  );
}
