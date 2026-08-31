import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/conversation_core/repository/conversation_repository.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _evidenceDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _resultDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _coverageDigest =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

class _FixtureContract implements ConversationContractMapper {
  const _FixtureContract();

  @override
  bool get isGenerated => false;

  @override
  Object get authorityProfile =>
      ConversationRepository.testFixtureAuthorityProfile;

  @override
  String get authorityId => 'test-fixture-conversation-contract-v1';

  ContractPreimage _encode(String kind, String value) {
    final bytes = utf8.encode('$kind|$value');
    return ContractPreimage(
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
      authorityId: authorityId,
      authorityProfile: authorityProfile,
      algorithm: 'TEST_FIXTURE_SHA256',
    );
  }

  String _json(Object? value) => jsonEncode(value);

  String _item(CanonicalItem value) => [
    value.providerTurnId,
    value.providerItemId,
    value.turnOrdinal,
    value.itemOrdinal,
    value.timelineOrdinal,
    value.kind,
    _json(value.normalizedPayload),
    _json(value.presentationProjection),
  ].join('|');

  String _gap(TypedGap value) => [
    value.gapId,
    value.kind.name,
    value.startOrdinal,
    value.endOrdinal,
    _json(value.details),
  ].join('|');

  @override
  ContractPreimage begin(MaterializationBegin value) => _encode(
    'begin',
    [
      value.materializationId,
      value.key.providerThreadId,
      value.fence.connectionEpoch,
      value.fence.sourceEpoch,
      value.fence.providerInstanceEpoch,
      value.fence.runtimeAuthorityGeneration,
      value.sourceRevision,
      value.pageCount,
      value.totalItemCount,
      value.coverage.structural.name,
      value.coverage.payload.name,
      value.coverage.lowerOrdinal,
      value.coverage.upperOrdinal,
      value.providerReadEvidenceDigest,
      value.providerReadEvidence?.method,
      value.providerReadEvidence?.buildId,
      value.providerReadEvidence?.resultKind,
      value.providerReadEvidence?.resultDigest,
      value.providerReadEvidence?.evidenceDigest,
      value.providerReadEvidence?.coverageDigest,
      value.requestId,
      value.readKind,
      value.emptyProof?.providerRevision,
    ].join('|'),
  );

  @override
  ContractPreimage pageBody(MaterializationPageBody value) => _encode(
    'page',
    [...value.items.map(_item), ...value.gaps.map(_gap)].join('||'),
  );

  @override
  ContractPreimage emptyProof(ReplicaEmptyProof value) => _encode(
    'empty',
    [
      value.proofKind.name,
      value.providerRevision,
      value.providerReadEvidenceDigest,
      value.observationDigest,
    ].join('|'),
  );

  @override
  ContractPreimage item(CanonicalItem value) => _encode('item', _item(value));

  @override
  ContractPreimage gap(TypedGap value) => _encode('gap', _gap(value));

  @override
  ContractPreimage envelope(RepositoryEnvelopeInput value) => _encode(
    'envelope',
    [
      value.envelopeId,
      value.key.providerThreadId,
      value.fence.sourceEpoch,
      value.fence.providerInstanceEpoch,
      value.sourceRevision,
      value.health.name,
      value.isSnapshot,
      value.items.map(_item).join('||'),
      value.gaps.map(_gap).join('||'),
    ].join('|'),
  );

  @override
  ContractPreimage orderProof(RepositoryOrderInput value) => _encode(
    'order',
    [
      value.materializationId,
      ...value.items.map(
        (item) =>
            '${item.providerTurnId}:${item.providerItemId}:${item.timelineOrdinal}',
      ),
      ...value.gaps.map((gap) => '${gap.gapId}:${gap.startOrdinal}'),
    ].join('|'),
  );

  @override
  ContractPreimage pageManifest(Iterable<String> pageDigests) =>
      _encode('manifest', pageDigests.join('|'));

  @override
  ContractPreimage runtimeProjection(RuntimeProjectionEnvelope value) =>
      _encode(
        'projection',
        [
          value.projectionId,
          value.key.providerThreadId,
          value.fence.sourceEpoch,
          value.fence.providerInstanceEpoch,
          value.fence.runtimeAuthorityGeneration,
          value.sourceRevision,
          value.operations.map((item) => item.operationId).join(','),
          value.queueEntries.map((item) => item.queueEntryId).join(','),
          value.interactions.map((item) => item.interactionId).join(','),
          value.operationSnapshotComplete,
          value.queueSnapshotComplete,
          value.interactionSnapshotComplete,
        ].join('|'),
      );

  @override
  ContractPreimage operationProjection(OperationProjection value) => _encode(
    'operation',
    [
      value.operationId,
      value.revision,
      value.state,
      value.isTerminal,
      _json(value.value),
    ].join('|'),
  );

  @override
  ContractPreimage queueEntryProjection(QueueEntryProjection value) => _encode(
    'queue',
    [
      value.queueEntryId,
      value.operationId,
      value.revision,
      value.position,
      value.state,
      _json(value.value),
    ].join('|'),
  );

  @override
  ContractPreimage interactionProjection(InteractionProjection value) =>
      _encode(
        'interaction',
        [
          value.interactionId,
          value.revision,
          value.kind,
          value.state,
          value.claimActorId,
          value.claimExpiresAt?.millisecondsSinceEpoch,
          _json(value.value),
        ].join('|'),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory tempDirectory;
  late ConversationRepository repository;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'conversation-v5-safety-',
    );
    repository = await _openRepository(tempDirectory);
  });

  tearDown(() async {
    await repository.close();
    if (tempDirectory.existsSync()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  group('projection safety', () {
    test('canonical epoch transition hides an older projection head', () async {
      await _materialize(
        repository,
        materializationId: 'canonical-source-1',
        sourceEpoch: 'source-1',
        providerEpoch: 'provider-1',
        connectionEpoch: 'connection-1',
        timelineOrdinal: 1,
      );
      final projectionReceipt = await repository.commitRuntimeProjections(
        _projection(
          'projection-source-1',
          sourceEpoch: 'source-1',
          providerEpoch: 'provider-1',
          connectionEpoch: 'connection-1',
          operationId: 'operation-source-1',
        ),
      );
      expect(
        projectionReceipt.window.operations.single.operationId,
        'operation-source-1',
      );

      final replacement = await _materialize(
        repository,
        materializationId: 'canonical-source-2',
        sourceEpoch: 'source-2',
        providerEpoch: 'provider-2',
        connectionEpoch: 'connection-2',
        timelineOrdinal: 2,
      );

      expect(replacement.window.fence!.sourceEpoch, 'source-2');
      expect(
        replacement.window.items.map((item) => item.timelineOrdinal),
        <int>[2],
      );
      expect(replacement.window.operations, isEmpty);
      expect((await repository.readWindow(_key())).operations, isEmpty);
    });

    test(
      'new authority partial projection starts a fresh snapshot marker',
      () async {
        await _materialize(
          repository,
          materializationId: 'partial-rollover-source-1',
          sourceEpoch: 'source-1',
          providerEpoch: 'provider-1',
          connectionEpoch: 'connection-1',
          timelineOrdinal: 1,
        );
        await repository.commitRuntimeProjections(
          _projection(
            'partial-rollover-projection-1',
            sourceEpoch: 'source-1',
            providerEpoch: 'provider-1',
            connectionEpoch: 'connection-1',
            operationId: 'partial-rollover-operation-1',
          ),
        );
        await _materialize(
          repository,
          materializationId: 'partial-rollover-source-2',
          sourceEpoch: 'source-2',
          providerEpoch: 'provider-2',
          connectionEpoch: 'connection-2',
          runtimeGeneration: 2,
          timelineOrdinal: 2,
        );

        final receipt = await repository.commitRuntimeProjections(
          _projection(
            'partial-rollover-projection-2',
            sourceEpoch: 'source-2',
            providerEpoch: 'provider-2',
            connectionEpoch: 'connection-2',
            runtimeGeneration: 2,
            operationId: 'partial-rollover-operation-2',
            operationSnapshotComplete: false,
          ),
        );

        expect(
          receipt.window.operations.map((value) => value.operationId),
          <String>['partial-rollover-operation-2'],
        );
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final head = (await inspection.query(
          'projection_head',
          columns: const <String>['operation_snapshot_marker'],
        )).single;
        await inspection.close();
        expect(
          head['operation_snapshot_marker'],
          'partial-rollover-projection-2',
        );
      },
    );

    test(
      'projection-only authority rollover advances its local fence',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'projection-only-authority-1',
            sourceEpoch: 'source-1',
            providerEpoch: 'provider-1',
            connectionEpoch: 'connection-1',
            operationId: 'projection-only-operation-1',
          ),
        );

        final receipt = await repository.commitRuntimeProjections(
          _projection(
            'projection-only-authority-2',
            sourceEpoch: 'source-2',
            providerEpoch: 'provider-2',
            connectionEpoch: 'connection-2',
            runtimeGeneration: 2,
            operationId: 'projection-only-operation-2',
          ),
        );

        expect(receipt.window.fence!.sourceEpoch, 'source-2');
        expect(receipt.window.fence!.providerInstanceEpoch, 'provider-2');
        expect(receipt.window.fence!.connectionEpoch, 'connection-2');
        expect(receipt.window.fence!.runtimeAuthorityGeneration, 2);
        expect(
          receipt.window.operations.map((value) => value.operationId),
          <String>['projection-only-operation-2'],
        );
      },
    );

    test(
      'open quarantines a pending projection retired after admission',
      () async {
        await repository.close();
        var failAfterAdmission = true;
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterInboxAdmission &&
                failAfterAdmission) {
              failAfterAdmission = false;
              throw StateError('simulated crash after projection admission');
            }
          },
        );
        await _materialize(
          repository,
          materializationId: 'recovery-source-1',
          sourceEpoch: 'source-1',
          providerEpoch: 'provider-1',
          connectionEpoch: 'connection-1',
          timelineOrdinal: 1,
        );
        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'pending-retired-projection',
              sourceEpoch: 'source-1',
              providerEpoch: 'provider-1',
              connectionEpoch: 'connection-1',
              operationId: 'pending-retired-operation',
            ),
          ),
          throwsStateError,
        );

        await _materialize(
          repository,
          materializationId: 'recovery-source-2',
          sourceEpoch: 'source-2',
          providerEpoch: 'provider-2',
          connectionEpoch: 'connection-2',
          timelineOrdinal: 2,
        );
        final databasePath = repository.resolvedDatabasePath!;
        await repository.close();

        repository = await _openRepository(tempDirectory);
        final inspection = await databaseFactoryFfi.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final inbox = await inspection.query(
          'projection_inbox',
          columns: const <String>['state'],
          where: 'projection_id = ?',
          whereArgs: const <Object?>['pending-retired-projection'],
        );
        await inspection.close();

        expect(inbox, hasLength(1));
        expect(inbox.single['state'], 'stale');
        final window = await repository.readWindow(_key());
        expect(window.items.map((item) => item.timelineOrdinal), <int>[2]);
        expect(window.operations, isEmpty);

        final retry = await repository.commitRuntimeProjections(
          _projection(
            'pending-retired-projection',
            sourceEpoch: 'source-1',
            providerEpoch: 'provider-1',
            connectionEpoch: 'connection-1',
            operationId: 'pending-retired-operation',
          ),
        );
        expect(retry.wasDuplicate, isTrue);
        expect(retry.wasPublished, isFalse);
        expect(retry.window.operations, isEmpty);
        final retryInspection = await databaseFactoryFfi.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final outbox = await retryInspection.query(
          'publication_outbox',
          where: 'domain = ? AND operation_id = ?',
          whereArgs: const <Object?>[
            'projection',
            'pending-retired-projection',
          ],
        );
        await retryInspection.close();
        expect(outbox, isEmpty);
      },
    );

    test('canonical revision advance hides an older projection head', () async {
      await _materialize(
        repository,
        materializationId: 'canonical-revision-1',
        sourceEpoch: 'source-1',
        providerEpoch: 'provider-1',
        connectionEpoch: 'connection-1',
        sourceRevision: 1,
        timelineOrdinal: 1,
      );
      await repository.commitRuntimeProjections(
        _projection(
          'projection-revision-1',
          sourceEpoch: 'source-1',
          providerEpoch: 'provider-1',
          connectionEpoch: 'connection-1',
          sourceRevision: 1,
          operationId: 'operation-revision-1',
        ),
      );

      final replacement = await _materialize(
        repository,
        materializationId: 'canonical-revision-2',
        sourceEpoch: 'source-1',
        providerEpoch: 'provider-1',
        connectionEpoch: 'connection-1',
        sourceRevision: 2,
        timelineOrdinal: 2,
      );

      expect(replacement.window.sourceRevision, 2);
      expect(replacement.window.operations, isEmpty);
      expect((await repository.readWindow(_key())).operations, isEmpty);
    });

    test(
      'canonical revision rejects an older projection before admission',
      () async {
        await _materialize(
          repository,
          materializationId: 'canonical-revision-2-preflight',
          sourceEpoch: 'source-1',
          providerEpoch: 'provider-1',
          connectionEpoch: 'connection-1',
          sourceRevision: 2,
          timelineOrdinal: 2,
        );

        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'projection-revision-1-preflight',
              sourceEpoch: 'source-1',
              providerEpoch: 'provider-1',
              connectionEpoch: 'connection-1',
              sourceRevision: 1,
              operationId: 'operation-revision-1-preflight',
            ),
          ),
          _failure(RepositoryFailureCode.staleRevision),
        );

        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final rows = await inspection.query(
          'projection_inbox',
          where: 'projection_id = ?',
          whereArgs: const <Object?>['projection-revision-1-preflight'],
        );
        await inspection.close();
        expect(rows, isEmpty);
      },
    );
    test('canonical advance between admission and apply terminalizes the projection', () async {
      await _materialize(
        repository,
        materializationId: 'canonical-race-revision-1',
        sourceEpoch: 'source-1',
        providerEpoch: 'provider-1',
        connectionEpoch: 'connection-1',
        sourceRevision: 1,
        timelineOrdinal: 1,
      );
      await repository.close();
      var advanceCanonical = true;
      repository = await _openRepository(
        tempDirectory,
        faultHook: (stage, operationId) async {
          if (stage == RepositoryFaultStage.afterInboxAdmission &&
              operationId == 'projection-race-revision-1' &&
              advanceCanonical) {
            advanceCanonical = false;
            await _materialize(
              repository,
              materializationId: 'canonical-race-revision-2',
              sourceEpoch: 'source-1',
              providerEpoch: 'provider-1',
              connectionEpoch: 'connection-1',
              sourceRevision: 2,
              timelineOrdinal: 2,
            );
          }
        },
      );

      await expectLater(
        repository.commitRuntimeProjections(
          _projection(
            'projection-race-revision-1',
            sourceEpoch: 'source-1',
            providerEpoch: 'provider-1',
            connectionEpoch: 'connection-1',
            sourceRevision: 1,
            operationId: 'operation-race-revision-1',
          ),
        ),
        _failure(RepositoryFailureCode.staleRevision),
      );

      final inspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final inbox = await inspection.query(
        'projection_inbox',
        columns: const <String>['state'],
        where: 'projection_id = ?',
        whereArgs: const <Object?>['projection-race-revision-1'],
      );
      final operations = await inspection.query(
        'operation_projection',
        where: 'operation_id = ?',
        whereArgs: const <Object?>['operation-race-revision-1'],
      );
      await inspection.close();
      expect(inbox, hasLength(1));
      expect(inbox.single['state'], 'stale');
      expect(operations, isEmpty);
      final window = await repository.readWindow(_key());
      expect(window.sourceRevision, 2);
      expect(window.operations, isEmpty);
    });

    test(
      'canonical generation rejects an older projection before admission',
      () async {
        await _materialize(
          repository,
          materializationId: 'canonical-generation-2',
          sourceEpoch: 'source-1',
          providerEpoch: 'provider-1',
          connectionEpoch: 'connection-2',
          runtimeGeneration: 2,
          timelineOrdinal: 1,
        );

        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'projection-generation-1',
              sourceEpoch: 'source-1',
              providerEpoch: 'provider-1',
              connectionEpoch: 'connection-2',
              runtimeGeneration: 1,
              operationId: 'operation-generation-1',
            ),
          ),
          _failure(RepositoryFailureCode.staleGeneration),
        );

        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final rows = await inspection.query(
          'projection_inbox',
          where: 'projection_id = ?',
          whereArgs: const <Object?>['projection-generation-1'],
        );
        await inspection.close();
        expect(rows, isEmpty);
        expect((await repository.readWindow(_key())).operations, isEmpty);
      },
    );

    test(
      'canonical connection fence rejects an equal-generation projection',
      () async {
        await _materialize(
          repository,
          materializationId: 'canonical-connection-2',
          sourceEpoch: 'source-1',
          providerEpoch: 'provider-1',
          connectionEpoch: 'connection-2',
          runtimeGeneration: 2,
          timelineOrdinal: 1,
        );

        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'projection-connection-3',
              sourceEpoch: 'source-1',
              providerEpoch: 'provider-1',
              connectionEpoch: 'connection-3',
              runtimeGeneration: 2,
              operationId: 'operation-connection-3',
            ),
          ),
          _failure(RepositoryFailureCode.staleEpoch),
        );

        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final rows = await inspection.query(
          'projection_inbox',
          where: 'projection_id = ?',
          whereArgs: const <Object?>['projection-connection-3'],
        );
        await inspection.close();
        expect(rows, isEmpty);
      },
    );

    test('recovery fails closed for a tampered pending inbox header', () async {
      await repository.close();
      var failAfterAdmission = true;
      repository = await _openRepository(
        tempDirectory,
        faultHook: (stage, _) async {
          if (stage == RepositoryFaultStage.afterInboxAdmission &&
              failAfterAdmission) {
            failAfterAdmission = false;
            throw StateError('simulated crash after projection admission');
          }
        },
      );
      await expectLater(
        repository.commitRuntimeProjections(
          _projection(
            'tampered-pending-projection',
            sourceEpoch: 'source-1',
            providerEpoch: 'provider-1',
            connectionEpoch: 'connection-1',
            operationId: 'tampered-pending-operation',
          ),
        ),
        throwsStateError,
      );
      final databasePath = repository.resolvedDatabasePath!;
      final inspection = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await inspection.update(
        'projection_inbox',
        const <String, Object?>{'connection_epoch': 'tampered-connection'},
        where: 'projection_id = ?',
        whereArgs: const <Object?>['tampered-pending-projection'],
      );
      await inspection.close();
      await repository.close();

      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: databasePath,
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );

      final after = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final inbox = await after.query(
        'projection_inbox',
        columns: const <String>['state'],
        where: 'projection_id = ?',
        whereArgs: const <Object?>['tampered-pending-projection'],
      );
      await after.close();
      expect(inbox, hasLength(1));
      expect(inbox.single['state'], 'pending');
    });
  });
}

Future<ConversationRepository> _openRepository(
  Directory directory, {
  RepositoryFaultHook? faultHook,
}) async {
  final repository = ConversationRepository.forTesting(
    databaseFactory: databaseFactoryFfi,
    databasePath: path.join(
      directory.path,
      ConversationRepository.defaultDatabaseName,
    ),
    contractMapper: const _FixtureContract(),
    faultHook: faultHook,
  );
  await repository.open();
  return repository;
}

ThreadKey _key() => const ThreadKey(
  partition: SourcePartition(
    bridgeIdentityId: 'bridge-identity',
    bridgeInstanceId: 'bridge-instance',
    codexSourceId: 'codex-source',
  ),
  providerThreadId: 'provider-thread',
);

ProviderReadEvidence _evidence() => const ProviderReadEvidence(
  method: 'thread/turns/list',
  buildId: 'codex-test-build',
  resultKind: 'full',
  resultDigest: _resultDigest,
  evidenceDigest: _evidenceDigest,
  coverageDigest: _coverageDigest,
);

CanonicalItem _item(int timelineOrdinal) => CanonicalItem(
  providerTurnId: 'turn-$timelineOrdinal',
  providerItemId: 'item-$timelineOrdinal',
  turnOrdinal: timelineOrdinal,
  itemOrdinal: 0,
  timelineOrdinal: timelineOrdinal,
  kind: 'USER_MESSAGE',
  normalizedPayload: <String, Object?>{'text': 'value-$timelineOrdinal'},
  presentationProjection: <String, Object?>{'text': 'value-$timelineOrdinal'},
);

Future<CommitReceipt> _materialize(
  ConversationRepository repository, {
  required String materializationId,
  required String connectionEpoch,
  required String sourceEpoch,
  required String providerEpoch,
  required int timelineOrdinal,
  int runtimeGeneration = 1,
  int sourceRevision = 1,
}) async {
  final begin = MaterializationBegin(
    materializationId: materializationId,
    key: _key(),
    fence: EnvelopeFence(
      connectionEpoch: connectionEpoch,
      sourceEpoch: sourceEpoch,
      providerInstanceEpoch: providerEpoch,
      runtimeAuthorityGeneration: runtimeGeneration,
    ),
    sourceRevision: sourceRevision,
    coverage: Coverage(
      structural: StructuralCoverage.complete,
      payload: PayloadCoverage.complete,
      lowerOrdinal: timelineOrdinal,
      upperOrdinal: timelineOrdinal,
    ),
    health: ReadHealth.healthy,
    pageCount: 1,
    totalItemCount: 1,
    providerReadEvidenceDigest: _evidenceDigest,
    providerReadEvidence: _evidence(),
    isSnapshot: true,
  );
  final body = MaterializationPageBody(
    items: <CanonicalItem>[_item(timelineOrdinal)],
  );
  final pageDigest = repository.materializationPageDigest(body);
  await repository.beginMaterialization(begin);
  await repository.stageMaterializationPage(
    MaterializationPage(
      materializationId: materializationId,
      key: begin.key,
      fence: begin.fence,
      sourceRevision: begin.sourceRevision,
      pageIndex: 0,
      pageCount: 1,
      pageDigest: pageDigest,
      body: body,
    ),
  );
  return repository.commitMaterialization(
    MaterializationCommit(
      materializationId: materializationId,
      key: begin.key,
      fence: begin.fence,
      sourceRevision: begin.sourceRevision,
      pageCount: 1,
      finalPageDigest: pageDigest,
      pageManifestDigest: repository.materializationPageManifestDigest(<String>[
        pageDigest,
      ]),
      providerReadEvidenceDigest: _evidenceDigest,
    ),
  );
}

RuntimeProjectionEnvelope _projection(
  String projectionId, {
  required String connectionEpoch,
  required String sourceEpoch,
  required String providerEpoch,
  required String operationId,
  int runtimeGeneration = 1,
  int sourceRevision = 1,
  bool operationSnapshotComplete = true,
}) => RuntimeProjectionEnvelope(
  projectionId: projectionId,
  key: _key(),
  fence: EnvelopeFence(
    connectionEpoch: connectionEpoch,
    sourceEpoch: sourceEpoch,
    providerInstanceEpoch: providerEpoch,
    runtimeAuthorityGeneration: runtimeGeneration,
  ),
  sourceRevision: sourceRevision,
  operations: <OperationProjection>[
    OperationProjection(
      operationId: operationId,
      revision: 1,
      state: 'queued',
      isTerminal: false,
      value: const <String, Object?>{'text': 'operation'},
    ),
  ],
  operationSnapshotComplete: operationSnapshotComplete,
);

Matcher _failure(RepositoryFailureCode code) => throwsA(
  isA<ConversationRepositoryException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);
