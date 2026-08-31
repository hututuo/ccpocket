import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
const _observationDigest =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

/// A deliberately non-production fixture adapter.  Its algorithm label keeps
/// it impossible to confuse this line encoding with RFC 8785; only the
/// visible-for-testing constructor accepts it.
class _FixtureContract implements ConversationContractMapper {
  const _FixtureContract({this.isGenerated = false});

  @override
  final bool isGenerated;

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
    tempDirectory = await Directory.systemTemp.createTemp('conversation-v8-');
    repository = await _openRepository(tempDirectory);
  });

  tearDown(() async {
    await repository.close();
    if (tempDirectory.existsSync()) await tempDirectory.delete(recursive: true);
  });

  group('contract authority seam', () {
    test(
      'default construction fails closed without generated outputs',
      () async {
        await repository.close();
        repository = ConversationRepository(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(tempDirectory.path, 'default.db'),
        );
        await repository.open();
        expect(
          () => repository.materializationPageDigest(MaterializationPageBody()),
          _failure(RepositoryFailureCode.contractUnavailable),
        );
        expect((await repository.readWindow(_key())).items, isEmpty);
      },
    );

    test('normal construction cannot enable a fixture adapter', () async {
      await repository.close();
      repository = ConversationRepository(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(tempDirectory.path, 'production.db'),
        contractMapper: const _FixtureContract(),
      );
      await repository.open();
      expect(
        () => repository.materializationPageDigest(MaterializationPageBody()),
        _failure(RepositoryFailureCode.contractUnavailable),
      );
    });

    test('a mapper cannot self-declare generated authority', () async {
      await repository.close();
      final forged = _FixtureContract(isGenerated: true);
      repository = ConversationRepository(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(tempDirectory.path, 'forged.db'),
        contractMapper: forged,
      );
      await repository.open();
      expect(
        () => repository.materializationPageDigest(MaterializationPageBody()),
        _failure(RepositoryFailureCode.contractUnavailable),
      );
    });

    test(
      'production readback does not skip verification for stored data',
      () async {
        final begin = _begin('readback-authority', revision: 1, totalItems: 1);
        final body = MaterializationPageBody(items: [_item(1)]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(begin);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        await repository.commitMaterialization(
          _commit(begin, digest, repository),
        );
        final dbPath = repository.resolvedDatabasePath!;
        await repository.close();
        repository = ConversationRepository(
          databaseFactory: databaseFactoryFfi,
          databasePath: dbPath,
        );
        await repository.open();
        await expectLater(
          repository.readWindow(_key()),
          _failure(RepositoryFailureCode.contractUnavailable),
        );
      },
    );

    test(
      'staging recomputes the mapper preimage after durable write',
      () async {
        final body = MaterializationPageBody(items: [_item(1)]);
        final begin = _begin('recompute', revision: 1, totalItems: 1);
        await repository.beginMaterialization(begin);
        final digest = repository.materializationPageDigest(body);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        final database = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await database.update(
          'staged_materialization_page',
          const <String, Object?>{'body_json': '{"items":[],"gaps":[]}'},
        );
        await database.close();
        final commit = _commit(begin, digest, repository);
        await expectLater(
          repository.commitMaterialization(commit),
          _failure(RepositoryFailureCode.digestMismatch),
        );
        expect((await repository.readWindow(_key())).lastGoodRevision, -1);
      },
    );

    test('seal recomputes the stored begin evidence preimage', () async {
      final begin = _begin('begin-evidence', revision: 1, totalItems: 1);
      final body = MaterializationPageBody(items: [_item(1)]);
      final digest = repository.materializationPageDigest(body);
      await repository.beginMaterialization(begin);
      await repository.stageMaterializationPage(
        _page(begin, body, digest: digest),
      );
      final inspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await inspection.update('staged_materialization', const <String, Object?>{
        'provider_result_kind': 'tampered',
      });
      await inspection.close();
      await expectLater(
        repository.commitMaterialization(_commit(begin, digest, repository)),
        _failure(RepositoryFailureCode.digestMismatch),
      );
      expect((await repository.readWindow(_key())).lastGoodRevision, -1);
    });

    test('typed empty requires exact evidence and provider revision', () async {
      final invalid = _begin(
        'bad-empty',
        revision: 1,
        pageCount: 0,
        totalItems: 0,
        health: ReadHealth.empty,
        emptyProof: const ReplicaEmptyProof(
          proofKind: ReplicaEmptyProofKind.providerAuthoritativeEmpty,
          providerReadEvidenceDigest: _evidenceDigest,
          observationDigest: _observationDigest,
        ),
      );
      await expectLater(
        repository.beginMaterialization(invalid),
        _failure(RepositoryFailureCode.invalidEnvelope),
      );
    });
  });

  group('materialization monotonicity', () {
    test('same-epoch complete snapshot removes an omitted item', () async {
      final first = _begin('first', revision: 1, totalItems: 2);
      final firstBody = MaterializationPageBody(items: [_item(1), _item(2)]);
      final firstDigest = repository.materializationPageDigest(firstBody);
      await repository.beginMaterialization(first);
      await repository.stageMaterializationPage(
        _page(first, firstBody, digest: firstDigest),
      );
      await repository.commitMaterialization(
        _commit(first, firstDigest, repository),
      );

      final second = _begin(
        'second',
        revision: 2,
        totalItems: 1,
        lower: 2,
        upper: 2,
        isSnapshot: false,
      );
      final secondBody = MaterializationPageBody(items: [_item(2)]);
      final secondDigest = repository.materializationPageDigest(secondBody);
      await repository.beginMaterialization(second);
      await repository.stageMaterializationPage(
        _page(second, secondBody, digest: secondDigest),
      );
      final receipt = await repository.commitMaterialization(
        _commit(second, secondDigest, repository),
      );
      expect(receipt.window.items.map((item) => item.timelineOrdinal), [2]);
      expect(receipt.window.lastGoodRevision, 2);
    });

    test('weak newer epoch retains the previous last-good timeline', () async {
      final first = _begin('good', revision: 1, totalItems: 1);
      final body = MaterializationPageBody(items: [_item(1)]);
      final digest = repository.materializationPageDigest(body);
      await repository.beginMaterialization(first);
      await repository.stageMaterializationPage(
        _page(first, body, digest: digest),
      );
      await repository.commitMaterialization(
        _commit(first, digest, repository),
      );

      final weak = _begin(
        'weak-new-epoch',
        revision: 1,
        sourceEpoch: 'source-2',
        providerEpoch: 'provider-2',
        health: ReadHealth.error,
        problemCode: 'timeout',
        pageCount: 1,
        totalItems: 0,
        lower: 0,
        upper: 0,
      );
      final weakBody = MaterializationPageBody(
        gaps: [
          TypedGap(
            gapId: 'gap-weak',
            kind: GapKind.unavailable,
            startOrdinal: 0,
            details: const <String, Object?>{'reason': 'timeout'},
          ),
        ],
      );
      final weakDigest = repository.materializationPageDigest(weakBody);
      await repository.beginMaterialization(weak);
      await repository.stageMaterializationPage(
        _page(weak, weakBody, digest: weakDigest),
      );
      final receipt = await repository.commitMaterialization(
        _commit(weak, weakDigest, repository),
      );
      expect(receipt.window.lastGoodRevision, 1);
      expect(receipt.window.items.single.timelineOrdinal, 1);
    });

    test(
      'a non-dominating partial cannot mutate visible canonical bytes',
      () async {
        final first = _begin('partial-base', revision: 1, totalItems: 1);
        final firstBody = MaterializationPageBody(items: [_item(1)]);
        final firstDigest = repository.materializationPageDigest(firstBody);
        await repository.beginMaterialization(first);
        await repository.stageMaterializationPage(
          _page(first, firstBody, digest: firstDigest),
        );
        await repository.commitMaterialization(
          _commit(first, firstDigest, repository),
        );

        final partial = _begin(
          'partial-new-observation',
          revision: 2,
          totalItems: 1,
          lower: 1,
          upper: 2,
          structural: StructuralCoverage.partial,
          isSnapshot: false,
        );
        final partialBody = MaterializationPageBody(
          items: [_item(2)],
          gaps: [
            TypedGap(
              gapId: 'partial-gap',
              kind: GapKind.unavailable,
              startOrdinal: 1,
              endOrdinal: 1,
            ),
          ],
        );
        final partialDigest = repository.materializationPageDigest(partialBody);
        await repository.beginMaterialization(partial);
        await repository.stageMaterializationPage(
          _page(partial, partialBody, digest: partialDigest),
        );
        final receipt = await repository.commitMaterialization(
          _commit(partial, partialDigest, repository),
        );

        expect(receipt.window.items.map((item) => item.timelineOrdinal), [1]);
        expect(receipt.window.gaps, isEmpty);
        expect(receipt.window.lastGoodRevision, 1);
        expect(receipt.window.sourceRevision, 2);
      },
    );

    test(
      'an exact verified empty snapshot replaces an old non-empty head',
      () async {
        final first = _begin('empty-base', revision: 1, totalItems: 1);
        final body = MaterializationPageBody(items: [_item(1)]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(first);
        await repository.stageMaterializationPage(
          _page(first, body, digest: digest),
        );
        await repository.commitMaterialization(
          _commit(first, digest, repository),
        );

        final proof = const ReplicaEmptyProof(
          proofKind: ReplicaEmptyProofKind.providerAuthoritativeEmpty,
          providerReadEvidenceDigest: _evidenceDigest,
          observationDigest: _observationDigest,
          providerRevision: 'provider-revision-2',
        );
        final empty = _begin(
          'empty-replacement',
          revision: 2,
          pageCount: 0,
          totalItems: 0,
          health: ReadHealth.empty,
          emptyProof: proof,
        );
        await repository.beginMaterialization(empty);
        final receipt = await repository.commitMaterialization(
          _commit(empty, '', repository),
        );

        expect(receipt.window.items, isEmpty);
        expect(receipt.window.gaps, isEmpty);
        expect(receipt.window.health, ReadHealth.empty);
        expect(receipt.window.lastGoodRevision, 2);
        expect(receipt.window.lastGoodSourceEpoch, 'source-1');
      },
    );

    test('page retry compares every durable page header', () async {
      final begin = _begin('page-header-retry', revision: 1, totalItems: 1);
      final body = MaterializationPageBody(items: [_item(1)]);
      final digest = repository.materializationPageDigest(body);
      await repository.beginMaterialization(begin);
      await repository.stageMaterializationPage(
        _page(begin, body, digest: digest),
      );
      await expectLater(
        repository.stageMaterializationPage(
          _page(
            begin,
            body,
            digest: digest,
            fence: const EnvelopeFence(
              connectionEpoch: 'connection-2',
              sourceEpoch: 'source-1',
              providerInstanceEpoch: 'provider-1',
              runtimeAuthorityGeneration: 1,
            ),
          ),
        ),
        _failure(RepositoryFailureCode.identityConflict),
      );
    });

    test(
      'materialization publication outbox recovers after apply crash',
      () async {
        var crashAfterApply = true;
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterCommit && crashAfterApply) {
              crashAfterApply = false;
              throw StateError('simulated crash after canonical apply');
            }
          },
        );
        final begin = _begin(
          'materialization-outbox',
          revision: 1,
          totalItems: 1,
        );
        final body = MaterializationPageBody(items: [_item(1)]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(begin);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        await expectLater(
          repository.commitMaterialization(_commit(begin, digest, repository)),
          throwsStateError,
        );
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          (await inspection.query(
            'publication_outbox',
            columns: const <String>['phase'],
          )).single['phase'],
          'applied',
        );
        await inspection.close();
        await repository.close();
        repository = await _openRepository(tempDirectory);
        final retry = await repository.commitMaterialization(
          _commit(begin, digest, repository),
        );
        expect(retry.wasDuplicate, isTrue);
        expect(retry.wasPublished, isTrue);
        expect(retry.window.items.single.timelineOrdinal, 1);
      },
    );

    test(
      'published notification replays after a crash before stream delivery',
      () async {
        var crashAfterPublication = true;
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterPublicationCommit &&
                crashAfterPublication) {
              crashAfterPublication = false;
              throw StateError('simulated crash after publication commit');
            }
          },
        );
        final begin = _begin(
          'materialization-published-replay',
          revision: 1,
          totalItems: 1,
        );
        final body = MaterializationPageBody(items: [_item(1)]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(begin);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        await expectLater(
          repository.commitMaterialization(_commit(begin, digest, repository)),
          throwsStateError,
        );
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final outbox = (await inspection.query('publication_outbox')).single;
        expect(outbox['phase'], 'published');
        expect(outbox['notification_state'], 'pending');
        await inspection.close();

        await repository.close();
        final recovered = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          contractMapper: const _FixtureContract(),
        );
        final updates = <RepositoryWindow>[];
        final subscription = recovered.updates.listen(updates.add);
        repository = recovered;
        await repository.open();
        expect(updates, hasLength(1));
        expect(updates.single.items.single.timelineOrdinal, 1);
        final replayEventId = updates.single.publicationEventId;
        expect(replayEventId, isNotNull);
        expect(await repository.acknowledgePublication(replayEventId!), isTrue);
        final readback = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          (await readback.query('publication_outbox'))
              .single['notification_state'],
          'notified',
        );
        await readback.close();
        await subscription.cancel();
      },
    );

    test(
      'delivering publication replays after a crash before stream delivery',
      () async {
        var crashAfterClaim = true;
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterPublicationCommit &&
                crashAfterClaim) {
              crashAfterClaim = false;
              throw StateError('simulated crash after delivery claim');
            }
          },
        );
        final beforeCrash = <RepositoryWindow>[];
        final beforeSubscription = repository.updates.listen(beforeCrash.add);
        final projection = _projection(
          'materialization-delivering-replay',
          revision: 1,
          operation: 'materialization-delivering-operation',
        );
        await expectLater(
          repository.commitRuntimeProjections(projection),
          throwsStateError,
        );
        expect(beforeCrash, isEmpty);
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final outbox = (await inspection.query('publication_outbox')).single;
        expect(outbox['notification_state'], 'delivering');
        expect(outbox['delivery_token'], isNotNull);
        await inspection.close();
        await beforeSubscription.cancel();
        await repository.close();

        final recovered = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          contractMapper: const _FixtureContract(),
        );
        final replayed = <RepositoryWindow>[];
        final replaySubscription = recovered.updates.listen(replayed.add);
        repository = recovered;
        await repository.open();
        expect(replayed, hasLength(1));
        final eventId = replayed.single.publicationEventId;
        expect(eventId, isNotNull);
        expect(await repository.acknowledgePublication(eventId!), isTrue);
        await replaySubscription.cancel();
      },
    );

    test('open recovery listener can acknowledge on the leased database immediately', () async {
      final projection = _projection(
        'publication-open-ack',
        revision: 1,
        operation: 'publication-open-ack-operation',
      );
      final first = await repository.commitRuntimeProjections(projection);
      expect(first.publicationEventId, isNotNull);
      await repository.close();

      final recovered = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      final replayed = <RepositoryWindow>[];
      final acknowledged = Completer<bool>();
      final subscription = recovered.updates.listen((window) {
        replayed.add(window);
        final eventId = window.publicationEventId;
        if (eventId == null) {
          if (!acknowledged.isCompleted) {
            acknowledged.completeError(
              StateError('open recovery omitted the publication identity'),
            );
          }
          return;
        }
        unawaited(
          recovered
              .acknowledgePublication(eventId)
              .then<void>(
                (value) {
                  if (!acknowledged.isCompleted) {
                    acknowledged.complete(value);
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (!acknowledged.isCompleted) {
                    acknowledged.completeError(error, stackTrace);
                  }
                },
              ),
        );
      });
      repository = recovered;
      await repository.open();
      expect(
        await acknowledged.future.timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(replayed, hasLength(1));
      final inspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(
        (await inspection.query('publication_outbox'))
            .single['notification_state'],
        'notified',
      );
      await inspection.close();
      await subscription.cancel();
    });

    test('publication identity stays pending without a listener until explicit ack', () async {
      final projection = _projection(
        'publication-ack-required',
        revision: 1,
        operation: 'publication-ack-operation',
      );
      final receipt = await repository.commitRuntimeProjections(projection);
      final eventId = receipt.publicationEventId;
      expect(eventId, isNotNull);
      expect(receipt.window.publicationEventId, eventId);
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final outbox = (await database.query('publication_outbox')).single;
      expect(outbox['event_id'], eventId);
      expect(outbox['notification_state'], 'pending');
      expect(outbox['delivery_token'], isNull);
      expect(await repository.acknowledgePublication(eventId!), isFalse);
      expect(
        (await database.query('publication_outbox'))
            .single['notification_state'],
        'pending',
      );
      await database.close();

      final update = await repository.updates.first.timeout(
        const Duration(seconds: 2),
      );
      expect(update.publicationEventId, eventId);
      expect(await repository.acknowledgePublication(eventId), isTrue);
      expect(await repository.acknowledgePublication(eventId), isTrue);
    });

    test('concurrent publishers claim one event identity and consumer ack is idempotent', () async {
      final updates = <RepositoryWindow>[];
      final subscription = repository.updates.listen(updates.add);
      final projection = _projection(
        'publication-concurrent',
        revision: 1,
        operation: 'publication-concurrent-operation',
      );
      final receipts = await Future.wait(<Future<CommitReceipt>>[
        repository.commitRuntimeProjections(projection),
        repository.commitRuntimeProjections(projection),
      ]);
      expect(updates, hasLength(1));
      expect(
        receipts
            .map((receipt) => receipt.publicationEventId)
            .whereType<String>()
            .toSet(),
        hasLength(1),
      );
      final eventId = updates.single.publicationEventId;
      expect(eventId, isNotNull);
      expect(await repository.acknowledgePublication(eventId!), isTrue);
      expect(await repository.acknowledgePublication(eventId), isTrue);
      await subscription.cancel();
    });

    test('a fresh foreign publication claim cannot be stolen by a duplicate publisher', () async {
      final projection = _projection(
        'publication-foreign-claim',
        revision: 1,
        operation: 'publication-foreign-claim-operation',
      );
      final first = await repository.commitRuntimeProjections(projection);
      final eventId = first.publicationEventId;
      expect(eventId, isNotNull);
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await database.update(
        'publication_outbox',
        <String, Object?>{
          'notification_state': 'delivering',
          'delivery_token': 'foreign-owner',
          'delivery_claimed_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'event_id = ?',
        whereArgs: <Object?>[eventId],
      );
      await database.close();

      final updates = <RepositoryWindow>[];
      final subscription = repository.updates.listen(updates.add);
      final duplicate = await repository.commitRuntimeProjections(projection);
      expect(duplicate.wasDuplicate, isTrue);
      expect(duplicate.wasPublished, isFalse);
      expect(updates, isEmpty);
      expect(await repository.acknowledgePublication(eventId!), isFalse);
      await subscription.cancel();
    });

    test('publication phase and notification state matrix rejects applied notified', () async {
      final projection = _projection(
        'publication-invalid-matrix',
        revision: 1,
        operation: 'publication-invalid-matrix-operation',
      );
      final first = await repository.commitRuntimeProjections(projection);
      final eventId = first.publicationEventId;
      expect(eventId, isNotNull);
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await database.execute('PRAGMA ignore_check_constraints = ON');
      await database.update(
        'publication_outbox',
        const <String, Object?>{
          'phase': 'applied',
          'notification_state': 'notified',
        },
        where: 'event_id = ?',
        whereArgs: <Object?>[eventId],
      );
      await database.close();
      await expectLater(
        repository.commitRuntimeProjections(projection),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('open rejects a corrupt publication matrix before contract or listener gates', () async {
      final projection = _projection(
        'publication-invalid-open-matrix',
        revision: 1,
        operation: 'publication-invalid-open-matrix-operation',
      );
      final first = await repository.commitRuntimeProjections(projection);
      final eventId = first.publicationEventId;
      expect(eventId, isNotNull);
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await database.execute('PRAGMA ignore_check_constraints = ON');
      await database.update(
        'publication_outbox',
        const <String, Object?>{
          'phase': 'applied',
          'notification_state': 'notified',
        },
        where: 'event_id = ?',
        whereArgs: <Object?>[eventId],
      );
      await database.close();
      await repository.close();
      // No fixture mapper and no listener are present.  The durable matrix
      // validator must run before either gate can hide the corruption.
      repository = ConversationRepository(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test(
      'publication recovery drains more than one bounded batch without reopen',
      () async {
        var failPublication = true;
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterPublicationCommit &&
                failPublication) {
              throw StateError('simulated publication handoff crash');
            }
          },
        );
        // Keep the listener absent so every durable hand-off remains pending.
        for (var index = 0; index < 65; index += 1) {
          await expectLater(
            repository.commitRuntimeProjections(
              _projection(
                'publication-batch-$index',
                revision: index + 1,
                operation: 'publication-batch-operation-$index',
              ),
            ),
            throwsStateError,
          );
        }
        final pendingDatabase = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          await pendingDatabase.query(
            'publication_outbox',
            where: 'notification_state = ?',
            whereArgs: const <Object?>['pending'],
          ),
          hasLength(65),
        );
        await pendingDatabase.close();
        failPublication = false;
        final updates = <RepositoryWindow>[];
        final drained = Completer<void>();
        final subscription = repository.updates.listen((window) {
          updates.add(window);
          if (updates.length == 65 && !drained.isCompleted) {
            drained.complete();
          }
        });
        await drained.future.timeout(const Duration(seconds: 5));
        expect(updates, hasLength(65));
        final eventIds = updates
            .map((window) => window.publicationEventId)
            .whereType<String>()
            .toList(growable: false);
        expect(eventIds, hasLength(65));
        expect(eventIds.toSet(), hasLength(65));
        for (final eventId in eventIds) {
          expect(await repository.acknowledgePublication(eventId), isTrue);
        }
        final after = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          await after.query(
            'publication_outbox',
            where: 'notification_state <> ?',
            whereArgs: const <Object?>['notified'],
          ),
          isEmpty,
        );
        await after.close();
        await subscription.cancel();
      },
    );

    test(
      'publication recovery resumes after a crash at the row-32 boundary',
      () async {
        final expectedEventIds = <String>[];
        for (var index = 0; index < 65; index += 1) {
          final receipt = await repository.commitRuntimeProjections(
            _projection(
              'publication-crash-boundary-$index',
              revision: index + 1,
              operation: 'publication-crash-boundary-operation-$index',
            ),
          );
          expectedEventIds.add(receipt.publicationEventId!);
        }
        await repository.close();

        var recoveryPublications = 0;
        final firstBatch = Completer<void>();
        final crashed = Completer<void>();
        final recovered = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          contractMapper: const _FixtureContract(),
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterPublicationCommit) {
              recoveryPublications += 1;
              if (recoveryPublications == 33) {
                if (!crashed.isCompleted) crashed.complete();
                throw StateError('simulated crash after publication row 32');
              }
            }
          },
        );
        repository = recovered;
        // Open without a listener first so the injected crash happens in the
        // ordinary post-open drain.  A real restart then uses a new owner
        // token, which is what makes row 33 reclaimable after row 32.
        await repository.open();
        final firstUpdates = <RepositoryWindow>[];
        final firstAcks = <Future<bool>>[];
        final firstSubscription = recovered.updates.listen((window) {
          firstUpdates.add(window);
          final eventId = window.publicationEventId;
          expect(eventId, isNotNull);
          firstAcks.add(recovered.acknowledgePublication(eventId!));
          if (firstUpdates.length == 32 && !firstBatch.isCompleted) {
            firstBatch.complete();
          }
        });
        await firstBatch.future.timeout(const Duration(seconds: 5));
        await crashed.future.timeout(const Duration(seconds: 5));
        expect(firstUpdates, hasLength(32));
        expect(await Future.wait(firstAcks), everyElement(isTrue));
        await firstSubscription.cancel();
        await repository.close();

        final retryUpdates = <RepositoryWindow>[];
        final retryAcks = <Future<bool>>[];
        final retryDrained = Completer<void>();
        final retry = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          contractMapper: const _FixtureContract(),
        );
        final retrySubscription = retry.updates.listen((window) {
          retryUpdates.add(window);
          final eventId = window.publicationEventId;
          expect(eventId, isNotNull);
          retryAcks.add(retry.acknowledgePublication(eventId!));
          if (retryUpdates.length == 33 && !retryDrained.isCompleted) {
            retryDrained.complete();
          }
        });
        repository = retry;
        await repository.open();
        await retryDrained.future.timeout(const Duration(seconds: 5));
        expect(retryUpdates, hasLength(33));
        expect(
          retryUpdates
              .map((window) => window.publicationEventId)
              .whereType<String>()
              .toSet(),
          hasLength(33),
        );
        expect(
          retryUpdates
              .map((window) => window.publicationEventId)
              .whereType<String>()
              .toSet(),
          containsAll(expectedEventIds.skip(32)),
        );
        expect(await Future.wait(retryAcks), everyElement(isTrue));
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          await inspection.query(
            'publication_outbox',
            where: 'notification_state <> ?',
            whereArgs: const <Object?>['notified'],
          ),
          isEmpty,
        );
        await inspection.close();
        await retrySubscription.cancel();
      },
    );

    test(
      'projection inbox recovery drains more than one bounded cursor batch',
      () async {
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterInboxAdmission) {
              throw StateError('simulated inbox admission crash');
            }
          },
        );
        for (var index = 0; index < 65; index += 1) {
          await expectLater(
            repository.commitRuntimeProjections(
              _projection(
                'inbox-batch-$index',
                revision: index + 1,
                operation: 'inbox-batch-operation-$index',
              ),
            ),
            throwsStateError,
          );
        }
        final pending = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          await pending.query(
            'projection_inbox',
            where: 'state = ?',
            whereArgs: const <Object?>['pending'],
          ),
          hasLength(65),
        );
        await pending.close();
        await repository.close();
        repository = await _openRepository(tempDirectory);
        final recovered = await repository.readWindow(_key());
        expect(recovered.operations, hasLength(65));
        final after = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          await after.query(
            'projection_inbox',
            where: 'state = ?',
            whereArgs: const <Object?>['pending'],
          ),
          isEmpty,
        );
        await after.close();
      },
    );
  });

  group('durable runtime projection', () {
    test('old complete snapshot cannot delete a newer projection', () async {
      final newer = _projection(
        'projection-2',
        revision: 2,
        operation: 'op-new',
      );
      final newerReceipt = await repository.commitRuntimeProjections(newer);
      expect(newerReceipt.window.operations.single.operationId, 'op-new');
      final old = _projection(
        'projection-1',
        revision: 1,
        complete: true,
        operation: null,
      );
      final oldReceipt = await repository.commitRuntimeProjections(old);
      expect(oldReceipt.wasPublished, isFalse);
      expect(
        (await repository.readWindow(_key())).operations.single.operationId,
        'op-new',
      );
    });

    test(
      'lower runtime authority generation cannot overtake the head',
      () async {
        final newerGeneration = _projection(
          'projection-generation-2',
          revision: 1,
          operation: 'op-generation-2',
          runtimeGeneration: 2,
        );
        await repository.commitRuntimeProjections(newerGeneration);
        final staleGeneration = _projection(
          'projection-generation-1',
          revision: 99,
          operation: 'op-generation-1',
          runtimeGeneration: 1,
        );
        final receipt = await repository.commitRuntimeProjections(
          staleGeneration,
        );
        expect(receipt.wasPublished, isFalse);
        expect(
          (await repository.readWindow(_key())).operations.single.operationId,
          'op-generation-2',
        );
      },
    );

    test(
      'an epoch change without a newer authority generation fails closed',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'projection-epoch-1',
            revision: 1,
            operation: 'op-epoch-1',
          ),
        );
        final ambiguous = _projection(
          'projection-epoch-ambiguous',
          revision: 2,
          operation: 'op-epoch-ambiguous',
          sourceEpoch: 'source-2',
        );
        await expectLater(
          repository.commitRuntimeProjections(ambiguous),
          _failure(RepositoryFailureCode.staleEpoch),
        );
        expect(
          (await repository.readWindow(_key())).operations.single.operationId,
          'op-epoch-1',
        );
      },
    );

    test(
      'inbox survives admission fault and exact retry is idempotent',
      () async {
        var failAdmission = true;
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterInboxAdmission &&
                failAdmission) {
              failAdmission = false;
              throw StateError('simulated process loss after inbox commit');
            }
          },
        );
        final projection = _projection(
          'projection-retry',
          revision: 1,
          operation: 'op-retry',
        );
        await expectLater(
          repository.commitRuntimeProjections(projection),
          throwsStateError,
        );
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          (await inspection.query(
            'projection_inbox',
            where: 'state = ?',
            whereArgs: ['pending'],
          )),
          hasLength(1),
        );
        expect(
          (await inspection.query(
            'projection_identity',
            columns: const <String>['disposition'],
            where: 'projection_id = ?',
            whereArgs: const <Object?>['projection-retry'],
          )).single['disposition'],
          'pending',
        );
        await inspection.close();
        await repository.close();
        repository = await _openRepository(tempDirectory);
        expect(
          (await repository.readWindow(_key())).operations.single.operationId,
          'op-retry',
        );
        final recovered = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          (await recovered.query(
            'projection_identity',
            columns: const <String>['disposition'],
            where: 'projection_id = ?',
            whereArgs: const <Object?>['projection-retry'],
          )).single['disposition'],
          'applied',
        );
        await recovered.close();
        final retry = await repository.commitRuntimeProjections(projection);
        expect(retry.wasDuplicate, isTrue);
        expect(retry.wasPublished, isTrue);
      },
    );
  });

  group('schema, lease, and guards', () {
    test('same canonical path has one writer lease', () async {
      final second = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: repository.resolvedDatabasePath,
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        second.open(),
        _failure(RepositoryFailureCode.writerLeaseUnavailable),
      );
      await second.close();
    });

    test(
      'idle live owner cannot be reclaimed from a stale heartbeat',
      () async {
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await inspection.update(
          'writer_lease',
          <String, Object?>{
            'heartbeat_at': DateTime.now()
                .subtract(const Duration(minutes: 3))
                .millisecondsSinceEpoch,
          },
          where: 'lease_name = ?',
          whereArgs: const <Object?>['conversation-repository-writer'],
        );
        await inspection.close();

        final second = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: repository.resolvedDatabasePath,
          contractMapper: const _FixtureContract(),
        );
        await expectLater(
          second.open(),
          _failure(RepositoryFailureCode.writerLeaseUnavailable),
        );
        await second.close();
      },
    );

    test(
      'same-PID isolate lease requires a liveness proof before reclaim',
      () async {
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await inspection.update(
          'writer_lease',
          <String, Object?>{
            'owner_pid': pid,
            'owner_boot_id': 'other-isolate-boot',
            'owner_process_instance_id': 'other-isolate-process',
            'heartbeat_at': DateTime.now()
                .subtract(const Duration(minutes: 3))
                .millisecondsSinceEpoch,
          },
          where: 'lease_name = ?',
          whereArgs: const <Object?>['conversation-repository-writer'],
        );
        await inspection.close();

        final second = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: repository.resolvedDatabasePath,
          contractMapper: const _FixtureContract(),
        );
        await expectLater(
          second.open(),
          _failure(RepositoryFailureCode.writerLeaseUnavailable),
        );
        await second.close();
      },
    );

    test('same-PID isolate cannot reclaim the live repository lease', () async {
      final responses = ReceivePort();
      final isolate = await Isolate.spawn(
        _samePidLeaseCompetingIsolate,
        <Object?>[responses.sendPort, repository.resolvedDatabasePath!],
      );
      try {
        expect(
          await responses.first.timeout(const Duration(seconds: 5)),
          'failure:writerLeaseUnavailable',
        );
      } finally {
        responses.close();
        isolate.kill(priority: Isolate.immediate);
      }
    });

    test('dead owner lease is reclaimable with a liveness proof', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.insert('writer_lease', <String, Object?>{
        'lease_name': 'conversation-repository-writer',
        'owner_token': 'dead-owner',
        'owner_pid': 999999,
        'owner_boot_id': 'old-boot',
        'owner_process_instance_id': 'old-process',
        'acquired_at': DateTime.now().millisecondsSinceEpoch,
        'heartbeat_at': DateTime.now().millisecondsSinceEpoch,
      });
      await database.close();
      repository = await _openRepository(
        tempDirectory,
        processLivenessProbe: (_) async => false,
      );
      final inspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final lease = (await inspection.query('writer_lease')).single;
      expect(lease['owner_token'], isNot('dead-owner'));
      await inspection.close();
    });

    test('retired epoch evidence has a bounded exact floor', () async {
      Future<void> commitMaterialization(
        MaterializationBegin begin,
        CanonicalItem item,
      ) async {
        final body = MaterializationPageBody(items: [item]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(begin);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        await repository.commitMaterialization(
          _commit(begin, digest, repository),
        );
      }

      await commitMaterialization(
        _begin('retired-floor-1', revision: 1, totalItems: 1),
        _item(1),
      );
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final partition = _key().partition;
      const insert = '''
INSERT OR IGNORE INTO retired_epoch
  (bridge_identity_id, bridge_instance_id, codex_source_id, epoch_kind, epoch_value, retired_at)
VALUES (?, ?, ?, ?, ?, ?)
''';
      for (
        var index = 0;
        index < ConversationRepository.maxRetiredEpochValuesPerKind - 1;
        index += 1
      ) {
        await database.rawInsert(insert, <Object?>[
          partition.bridgeIdentityId,
          partition.bridgeInstanceId,
          partition.codexSourceId,
          'source',
          'seed-source-$index',
          DateTime.now().millisecondsSinceEpoch,
        ]);
      }
      final beforeDuplicate = await database.rawQuery(
        'SELECT COUNT(*) AS count FROM retired_epoch WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND epoch_kind = ?',
        <Object?>[
          partition.bridgeIdentityId,
          partition.bridgeInstanceId,
          partition.codexSourceId,
          'source',
        ],
      );
      await database.rawInsert(insert, <Object?>[
        partition.bridgeIdentityId,
        partition.bridgeInstanceId,
        partition.codexSourceId,
        'source',
        'seed-source-0',
        DateTime.now().millisecondsSinceEpoch,
      ]);
      final afterDuplicate = await database.rawQuery(
        'SELECT COUNT(*) AS count FROM retired_epoch WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND epoch_kind = ?',
        <Object?>[
          partition.bridgeIdentityId,
          partition.bridgeInstanceId,
          partition.codexSourceId,
          'source',
        ],
      );
      expect(afterDuplicate.single['count'], beforeDuplicate.single['count']);
      await database.close();

      await commitMaterialization(
        _begin(
          'retired-floor-boundary',
          revision: 2,
          totalItems: 1,
          sourceEpoch: 'source-2',
          lower: 2,
          upper: 2,
        ),
        _item(2),
      );
      final boundaryInspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final countAtBoundary = await boundaryInspection.rawQuery(
        'SELECT COUNT(*) AS count FROM retired_epoch WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND epoch_kind = ?',
        <Object?>[
          partition.bridgeIdentityId,
          partition.bridgeInstanceId,
          partition.codexSourceId,
          'source',
        ],
      );
      expect(
        countAtBoundary.single['count'],
        ConversationRepository.maxRetiredEpochValuesPerKind,
      );
      await boundaryInspection.close();

      final rejected = _begin(
        'retired-floor-over-cap',
        revision: 3,
        totalItems: 1,
        sourceEpoch: 'source-3',
        lower: 3,
        upper: 3,
      );
      final rejectedBody = MaterializationPageBody(items: [_item(3)]);
      final rejectedDigest = repository.materializationPageDigest(rejectedBody);
      await repository.beginMaterialization(rejected);
      await repository.stageMaterializationPage(
        _page(rejected, rejectedBody, digest: rejectedDigest),
      );
      await expectLater(
        repository.commitMaterialization(
          _commit(rejected, rejectedDigest, repository),
        ),
        _failure(RepositoryFailureCode.capacityExceeded),
      );
      final window = await repository.readWindow(_key());
      expect(window.lastGoodRevision, 2);
      expect(window.items.single.timelineOrdinal, 2);
    });

    test('pressure GC keeps the retired epoch rollback floor', () async {
      Future<void> commitMaterialization(
        MaterializationBegin begin,
        CanonicalItem item,
      ) async {
        final body = MaterializationPageBody(items: [item]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(begin);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        await repository.commitMaterialization(
          _commit(begin, digest, repository),
        );
      }

      await commitMaterialization(
        _begin('pressure-floor-1', revision: 1, totalItems: 1),
        _item(1),
      );
      await commitMaterialization(
        _begin(
          'pressure-floor-2',
          revision: 2,
          totalItems: 1,
          sourceEpoch: 'source-2',
          lower: 2,
          upper: 2,
        ),
        _item(2),
      );

      await repository.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
        maxEntriesPerThread: 20,
      );
      await repository.open();
      final inspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      for (var index = 0; index < 16; index += 1) {
        await inspection.insert('operation_projection', <String, Object?>{
          ...<String, Object?>{
            'bridge_identity_id': key.partition.bridgeIdentityId,
            'bridge_instance_id': key.partition.bridgeInstanceId,
            'codex_source_id': key.partition.codexSourceId,
            'provider_thread_id': key.providerThreadId,
          },
          'operation_id': 'inactive-$index',
          'revision': 1,
          'state': 'queued',
          'is_terminal': 0,
          'value_json': '{}',
          'value_digest': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          'is_active': 0,
          'gc_eligible': 0,
          'snapshot_marker': '',
          'source_projection_id': '',
        });
      }
      await inspection.close();

      await repository.commitRuntimeProjections(
        _projection(
          'pressure-floor-projection',
          revision: 3,
          operation: 'pressure-floor-operation',
          sourceEpoch: 'source-2',
        ),
      );
      final floorInspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final retired = await floorInspection.query(
        'retired_epoch',
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND epoch_kind = ? AND epoch_value = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          'source',
          'source-1',
        ],
      );
      expect(retired, hasLength(1));
      await floorInspection.close();

      final oldEpoch = _begin(
        'pressure-floor-old-epoch',
        revision: 3,
        totalItems: 1,
        sourceEpoch: 'source-1',
        lower: 3,
        upper: 3,
      );
      final oldBody = MaterializationPageBody(items: [_item(3)]);
      final oldDigest = repository.materializationPageDigest(oldBody);
      await repository.beginMaterialization(oldEpoch);
      await repository.stageMaterializationPage(
        _page(oldEpoch, oldBody, digest: oldDigest),
      );
      await expectLater(
        repository.commitMaterialization(
          _commit(oldEpoch, oldDigest, repository),
        ),
        _failure(RepositoryFailureCode.staleEpoch),
      );
    });

    test(
      'stale owner cannot mutate after a replacement lease is installed',
      () async {
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await inspection.delete('writer_lease');
        await inspection.insert('writer_lease', <String, Object?>{
          'lease_name': 'conversation-repository-writer',
          'owner_token': 'replacement-owner',
          'owner_pid': 123,
          'owner_boot_id': 'replacement-boot',
          'owner_process_instance_id': 'replacement-process',
          'acquired_at': DateTime.now().millisecondsSinceEpoch,
          'heartbeat_at': DateTime.now().millisecondsSinceEpoch,
        });
        await inspection.close();
        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'lease-fenced-projection',
              revision: 1,
              operation: 'op',
            ),
          ),
          _failure(RepositoryFailureCode.writerLeaseUnavailable),
        );
        await repository.close();
        final leaseInspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final lease = (await leaseInspection.query('writer_lease')).single;
        expect(lease['owner_token'], 'replacement-owner');
        await leaseInspection.close();
      },
    );

    test('foreign schema missing an attested index is rejected', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('DROP INDEX canonical_item_window_idx');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('schema attestation rejects an index collation change', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('DROP INDEX canonical_item_window_idx');
      await database.execute('''
        CREATE INDEX canonical_item_window_idx ON canonical_item (
          bridge_identity_id COLLATE NOCASE,
          bridge_instance_id,
          codex_source_id,
          provider_thread_id,
          timeline_ordinal
        )
      ''');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test(
      'schema attestation rejects unexpected trigger and hidden columns',
      () async {
        await repository.close();
        final database = await databaseFactoryFfi.openDatabase(
          path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
        );
        await database.execute(
          'CREATE TRIGGER unexpected_trigger AFTER INSERT ON thread_state BEGIN SELECT 1; END',
        );
        await database.close();
        repository = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          contractMapper: const _FixtureContract(),
        );
        await expectLater(
          repository.open(),
          _failure(RepositoryFailureCode.invalidDatabaseIdentity),
        );
      },
    );

    test(
      'schema attestation checks table_xinfo hidden/generated columns',
      () async {
        await repository.close();
        final database = await databaseFactoryFfi.openDatabase(
          path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
        );
        await database.execute(
          'ALTER TABLE thread_state ADD COLUMN hidden_marker TEXT GENERATED ALWAYS AS (provider_thread_id) VIRTUAL',
        );
        await database.close();
        repository = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          contractMapper: const _FixtureContract(),
        );
        await expectLater(
          repository.open(),
          _failure(RepositoryFailureCode.invalidDatabaseIdentity),
        );
      },
    );

    test('schema attestation rejects a weakened CHECK expression', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('PRAGMA writable_schema = ON');
      await database.rawUpdate(
        "UPDATE sqlite_master SET sql = REPLACE(sql, ?, ?) WHERE type = 'table' AND name = ?",
        <Object?>[
          "CHECK (state_kind IN ('canonical', 'projection_only'))",
          "CHECK (state_kind IN ('canonical', 'projection_only') OR 1)",
          'thread_state',
        ],
      );
      await database.execute('PRAGMA writable_schema = OFF');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('schema attestation rejects an unexpected column default', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('PRAGMA writable_schema = ON');
      await database.rawUpdate(
        "UPDATE sqlite_master SET sql = REPLACE(sql, ?, ?) WHERE type = 'table' AND name = ?",
        <Object?>[
          'state_kind TEXT NOT NULL',
          "state_kind TEXT NOT NULL DEFAULT 'canonical'",
          'thread_state',
        ],
      );
      await database.execute('PRAGMA writable_schema = OFF');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('schema attestation rejects a PK conflict policy', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('PRAGMA writable_schema = ON');
      await database.rawUpdate(
        "UPDATE sqlite_master SET sql = REPLACE(sql, ?, ?) WHERE type = 'table' AND name = ?",
        <Object?>[
          'PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)',
          'PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id) ON CONFLICT REPLACE',
          'thread_state',
        ],
      );
      await database.execute('PRAGMA writable_schema = OFF');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('schema attestation rejects deferred foreign keys', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('PRAGMA writable_schema = ON');
      await database.rawUpdate(
        "UPDATE sqlite_master SET sql = REPLACE(sql, ?, ?) WHERE type = 'table' AND name = ?",
        <Object?>[
          'ON DELETE CASCADE',
          'ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED',
          'canonical_item',
        ],
      );
      await database.execute('PRAGMA writable_schema = OFF');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('schema attestation rejects a WITHOUT ROWID table option', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('PRAGMA writable_schema = ON');
      await database.rawUpdate(
        "UPDATE sqlite_master SET sql = REPLACE(sql, ?, ?) WHERE type = 'table' AND name = ?",
        <Object?>[') STRICT', ') STRICT, WITHOUT ROWID', 'thread_state'],
      );
      await database.execute('PRAGMA writable_schema = OFF');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('schema v7 to v8 open is an explicit fail-closed boundary', () async {
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
      );
      await database.execute('PRAGMA user_version = 7');
      await database.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(
          tempDirectory.path,
          ConversationRepository.defaultDatabaseName,
        ),
        contractMapper: const _FixtureContract(),
      );
      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('new v8 default preserves v7/v6/v5 files', () async {
      await repository.close();
      final legacyV7Path = path.join(
        tempDirectory.path,
        'conversation_replica_v7.db',
      );
      await _createLegacyV7Database(legacyV7Path, 'v7-preserved');
      final beforeV7 = await File(legacyV7Path).readAsBytes();
      final legacyV6Path = path.join(
        tempDirectory.path,
        'conversation_replica_v6.db',
      );
      await _createLegacyV6Database(legacyV6Path, 'v6-preserved');
      final beforeV6 = await File(legacyV6Path).readAsBytes();
      final legacyPath = path.join(
        tempDirectory.path,
        'conversation_replica_v5.db',
      );
      await _createLegacyV5Database(legacyPath, 'v5-preserved');
      final before = await File(legacyPath).readAsBytes();

      repository = await _openRepository(tempDirectory);

      expect(
        path.basename(repository.resolvedDatabasePath!),
        ConversationRepository.defaultDatabaseName,
      );
      expect(
        ConversationRepository.defaultDatabaseName,
        'conversation_replica_v8.db',
      );
      final current = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(
        (await current.query('replica_metadata')).single,
        containsPair('schema_identity', 'ccpocket.conversation_replica_v8'),
      );
      expect(
        (await current.query('replica_metadata')).single,
        containsPair('schema_version', 8),
      );
      expect(
        (await current.rawQuery('PRAGMA user_version')).single['user_version'],
        8,
      );
      expect(
        (await current.rawQuery('PRAGMA table_info(projection_identity)'))
            .map((row) => row['name'])
            .toList(),
        <Object?>[
          'bridge_identity_id',
          'bridge_instance_id',
          'codex_source_id',
          'provider_thread_id',
          'projection_id',
          'connection_epoch',
          'source_epoch',
          'provider_instance_epoch',
          'runtime_authority_generation',
          'source_revision',
          'projection_digest',
          'disposition',
        ],
      );
      expect(
        (await current.rawQuery(
          'PRAGMA index_info(projection_identity_pending_idx)',
        )).map((row) => row['name']).toList(),
        <Object?>[
          'disposition',
          'bridge_identity_id',
          'bridge_instance_id',
          'codex_source_id',
          'provider_thread_id',
          'projection_id',
        ],
      );
      expect(
        (await current.rawQuery('PRAGMA index_info(projection_inbox_gc_idx)'))
            .map((row) => row['name'])
            .toList(),
        <Object?>[
          'bridge_identity_id',
          'bridge_instance_id',
          'codex_source_id',
          'provider_thread_id',
          'gc_eligible',
          'state',
          'admitted_at',
          'projection_id',
        ],
      );
      await current.close();
      expect(await File(legacyV7Path).readAsBytes(), beforeV7);
      expect(await File(legacyV6Path).readAsBytes(), beforeV6);
      expect(await File(legacyPath).readAsBytes(), before);
      final v7Readback = await databaseFactoryFfi.openDatabase(
        legacyV7Path,
        options: OpenDatabaseOptions(version: 7),
      );
      expect(
        (await v7Readback.query('legacy_v7_marker')).single['value'],
        'v7-preserved',
      );
      expect(
        (await v7Readback.rawQuery('PRAGMA user_version'))
            .single['user_version'],
        7,
      );
      await v7Readback.close();
      final v6Readback = await databaseFactoryFfi.openDatabase(
        legacyV6Path,
        options: OpenDatabaseOptions(version: 6),
      );
      expect(
        (await v6Readback.query('legacy_v6_marker')).single['value'],
        'v6-preserved',
      );
      expect(
        (await v6Readback.rawQuery('PRAGMA user_version'))
            .single['user_version'],
        6,
      );
      await v6Readback.close();
      final readback = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(version: 5),
      );
      expect(
        (await readback.query('legacy_v5_marker')).single['value'],
        'v5-preserved',
      );
      expect(
        (await readback.rawQuery('PRAGMA index_info(projection_inbox_gc_idx)'))
            .map((row) => row['name'])
            .toList(),
        <Object?>[
          'bridge_identity_id',
          'bridge_instance_id',
          'codex_source_id',
          'provider_thread_id',
          'admitted_at',
          'projection_id',
          'state',
        ],
      );
      expect(
        (await readback.rawQuery('PRAGMA user_version')).single['user_version'],
        5,
      );
      await readback.close();
    });

    test('explicit v7 database path is rejected without mutation', () async {
      await repository.close();
      final legacyPath = path.join(
        tempDirectory.path,
        'conversation_replica_v7.db',
      );
      await _createLegacyV7Database(legacyPath, 'v7-explicit');
      final before = await File(legacyPath).readAsBytes();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: legacyPath,
        contractMapper: const _FixtureContract(),
      );

      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
      expect(await File(legacyPath).readAsBytes(), before);
    });

    test('explicit v6 database path is rejected without mutation', () async {
      await repository.close();
      final legacyPath = path.join(
        tempDirectory.path,
        'conversation_replica_v6.db',
      );
      await _createLegacyV6Database(legacyPath, 'v6-explicit');
      final before = await File(legacyPath).readAsBytes();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: legacyPath,
        contractMapper: const _FixtureContract(),
      );

      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
      expect(await File(legacyPath).readAsBytes(), before);
    });

    test('explicit v5 database path is rejected without mutation', () async {
      await repository.close();
      final legacyPath = path.join(
        tempDirectory.path,
        'conversation_replica_v5.db',
      );
      await _createLegacyV5Database(legacyPath, 'v5-explicit');
      final before = await File(legacyPath).readAsBytes();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: legacyPath,
        contractMapper: const _FixtureContract(),
      );

      await expectLater(
        repository.open(),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
      expect(await File(legacyPath).readAsBytes(), before);
    });

    test('schema uses one bijective composite foreign-key group', () async {
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final foreignKeys = await database.rawQuery(
        'PRAGMA foreign_key_list(canonical_item)',
      );
      expect(foreignKeys, hasLength(4));
      expect(foreignKeys.map((row) => row['id']).toSet(), hasLength(1));
      expect(foreignKeys.map((row) => row['seq']).toList(), [0, 1, 2, 3]);
      await database.close();
    });

    test('pressure GC candidate queries use bounded-order indexes', () async {
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final keyArgs = <Object?>[
        _key().partition.bridgeIdentityId,
        _key().partition.bridgeInstanceId,
        _key().partition.codexSourceId,
        _key().providerThreadId,
      ];
      Future<String> plan(String sql, List<Object?> args) async {
        final rows = await database.rawQuery(sql, args);
        return rows.map((row) => '${row['detail']}').join(' | ');
      }

      final checks = <String, Future<String>>{
        'publication_outbox_recovery_idx': plan(
          'EXPLAIN QUERY PLAN SELECT event_id FROM publication_outbox WHERE phase = ? AND notification_state = ? ORDER BY published_at ASC, event_id ASC LIMIT 32',
          const <Object?>['published', 'pending'],
        ),
        'publication_outbox_phase_idx': plan(
          'EXPLAIN QUERY PLAN SELECT source_epoch, provider_instance_epoch, domain, operation_id FROM publication_outbox WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND phase = ? AND notification_state = ? ORDER BY published_at ASC, operation_id ASC LIMIT 32',
          [...keyArgs, 'published', 'notified'],
        ),
        'publication_outbox_provenance_idx': plan(
          'EXPLAIN QUERY PLAN SELECT operation_id FROM publication_outbox WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND domain = ? AND operation_id = ? AND notification_state IN (?, ?) LIMIT 1',
          [...keyArgs, 'projection', 'projection-id', 'pending', 'delivering'],
        ),
        'projection_inbox_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT projection_id FROM projection_inbox WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND gc_eligible = ? AND state IN (?, ?) ORDER BY state ASC, admitted_at ASC, projection_id ASC LIMIT 32',
          [...keyArgs, 1, 'applied', 'stale'],
        ),
        'projection_inbox_recovery_idx': plan(
          'EXPLAIN QUERY PLAN SELECT projection_id FROM projection_inbox WHERE state = ? ORDER BY admitted_at ASC, projection_id ASC, bridge_identity_id ASC, bridge_instance_id ASC, codex_source_id ASC, provider_thread_id ASC LIMIT 32',
          const <Object?>['pending'],
        ),
        'projection_identity_pending_idx': plan(
          '''
          EXPLAIN QUERY PLAN
          SELECT 1
          FROM projection_identity AS identity_row
          LEFT JOIN projection_inbox AS inbox
            ON inbox.bridge_identity_id = identity_row.bridge_identity_id
            AND inbox.bridge_instance_id = identity_row.bridge_instance_id
            AND inbox.codex_source_id = identity_row.codex_source_id
            AND inbox.provider_thread_id = identity_row.provider_thread_id
            AND inbox.projection_id = identity_row.projection_id
          WHERE identity_row.disposition = ?
            AND (
              inbox.projection_id IS NULL
              OR inbox.state <> ?
              OR inbox.connection_epoch <> identity_row.connection_epoch
              OR inbox.source_epoch <> identity_row.source_epoch
              OR inbox.provider_instance_epoch <> identity_row.provider_instance_epoch
              OR inbox.runtime_authority_generation <> identity_row.runtime_authority_generation
              OR inbox.source_revision <> identity_row.source_revision
              OR inbox.projection_digest <> identity_row.projection_digest
            )
          LIMIT 1
          ''',
          const <Object?>['pending', 'pending'],
        ),
        'operation_projection_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT operation_id FROM operation_projection WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 0 ORDER BY operation_id ASC LIMIT 32',
          keyArgs,
        ),
        'queue_entry_projection_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT queue_entry_id FROM queue_entry_projection WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 0 ORDER BY queue_entry_id ASC LIMIT 32',
          keyArgs,
        ),
        'interaction_projection_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT interaction_id FROM interaction_projection WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 0 ORDER BY interaction_id ASC LIMIT 32',
          keyArgs,
        ),
        'operation_projection_snapshot_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT operation_id FROM operation_projection WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 1 AND gc_eligible = 1 AND snapshot_marker < ? ORDER BY snapshot_marker ASC, operation_id ASC LIMIT 32',
          [...keyArgs, 'current-snapshot'],
        ),
        'queue_entry_projection_snapshot_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT queue_entry_id FROM queue_entry_projection WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 1 AND gc_eligible = 1 AND snapshot_marker < ? ORDER BY snapshot_marker ASC, queue_entry_id ASC LIMIT 32',
          [...keyArgs, 'current-snapshot'],
        ),
        'interaction_projection_snapshot_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT interaction_id FROM interaction_projection WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 1 AND gc_eligible = 1 AND snapshot_marker < ? ORDER BY snapshot_marker ASC, interaction_id ASC LIMIT 32',
          [...keyArgs, 'current-snapshot'],
        ),
        'operation_projection_source_projection_idx': plan(
          'EXPLAIN QUERY PLAN UPDATE operation_projection SET gc_eligible = 1 WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_projection_id = ?',
          [...keyArgs, 'projection-id'],
        ),
        'queue_entry_projection_source_projection_idx': plan(
          'EXPLAIN QUERY PLAN UPDATE queue_entry_projection SET gc_eligible = 1 WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_projection_id = ?',
          [...keyArgs, 'projection-id'],
        ),
        'interaction_projection_source_projection_idx': plan(
          'EXPLAIN QUERY PLAN UPDATE interaction_projection SET gc_eligible = 1 WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_projection_id = ?',
          [...keyArgs, 'projection-id'],
        ),
        'typed_gap_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT gap_id FROM typed_gap WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 0 ORDER BY gap_id ASC LIMIT 32',
          keyArgs,
        ),
        'committed_envelope_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT source_epoch, provider_instance_epoch, envelope_id, connection_epoch, source_revision FROM committed_envelope WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? ORDER BY committed_at ASC, envelope_id ASC LIMIT 32',
          keyArgs,
        ),
        'staged_materialization_gc_idx': plan(
          'EXPLAIN QUERY PLAN SELECT source_epoch, provider_instance_epoch, materialization_id, connection_epoch, source_revision FROM staged_materialization WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? ORDER BY begun_at DESC, materialization_id DESC LIMIT 32',
          keyArgs,
        ),
      };
      for (final entry in checks.entries) {
        final detail = await entry.value;
        expect(detail, contains(entry.key));
        expect(detail, isNot(contains('USE TEMP B-TREE')));
      }
      expect(
        await checks['projection_inbox_gc_idx'],
        allOf(contains('gc_eligible=?'), contains('state=?')),
      );
      expect(
        await checks['projection_identity_pending_idx'],
        allOf(
          contains('disposition=?'),
          contains(
            'SEARCH inbox USING INDEX sqlite_autoindex_projection_inbox_1',
          ),
          isNot(contains('SCAN identity_row')),
          isNot(contains('SCAN inbox')),
        ),
      );
      for (final indexName in const <String>[
        'operation_projection_snapshot_gc_idx',
        'queue_entry_projection_snapshot_gc_idx',
        'interaction_projection_snapshot_gc_idx',
      ]) {
        expect(await checks[indexName], contains('snapshot_marker<?'));
      }
      for (final entry in <(String, String)>[
        ('operation_projection_snapshot_gc_idx', 'operation_id'),
        ('queue_entry_projection_snapshot_gc_idx', 'queue_entry_id'),
        ('interaction_projection_snapshot_gc_idx', 'interaction_id'),
      ]) {
        final detail = await plan(
          'EXPLAIN QUERY PLAN SELECT ${entry.$2} FROM ${entry.$1.replaceFirst('_snapshot_gc_idx', '')} WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 1 AND gc_eligible = 1 AND snapshot_marker > ? ORDER BY snapshot_marker ASC, ${entry.$2} ASC LIMIT 32',
          [...keyArgs, 'current-snapshot'],
        );
        expect(detail, contains(entry.$1));
        expect(detail, contains('gc_eligible=?'));
        expect(detail, contains('snapshot_marker>?'));
        expect(detail, isNot(contains('USE TEMP B-TREE')));
      }
      final stalePublicationDetail = await plan(
        'EXPLAIN QUERY PLAN SELECT event_id FROM publication_outbox WHERE phase = ? AND notification_state = ? AND (delivery_claimed_at IS NULL OR delivery_claimed_at < ?) ORDER BY published_at ASC, event_id ASC LIMIT 32',
        const <Object?>['published', 'delivering', 0],
      );
      expect(
        stalePublicationDetail,
        contains('publication_outbox_recovery_idx'),
      );
      expect(stalePublicationDetail, isNot(contains('USE TEMP B-TREE')));
      await database.close();
    });

    test('ACK eligibility updates only rows from the indexed projection', () async {
      final subscription = repository.updates.listen((_) {});
      const sourceA = 'ack-index-projection-a';
      const sourceB = 'ack-index-projection-b';
      final a = await repository.commitRuntimeProjections(
        _projection(sourceA, revision: 1, operation: 'ack-index-primary-a'),
      );
      await repository.commitRuntimeProjections(
        _projection(sourceB, revision: 2, operation: 'ack-index-primary-b'),
      );
      expect(a.publicationEventId, isNotNull);

      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final keyColumns = <String, Object?>{
        'bridge_identity_id': _key().partition.bridgeIdentityId,
        'bridge_instance_id': _key().partition.bridgeInstanceId,
        'codex_source_id': _key().partition.codexSourceId,
        'provider_thread_id': _key().providerThreadId,
      };
      for (final source in const <String>[sourceA, sourceB]) {
        for (var index = 0; index < 40; index += 1) {
          final suffix = index.toString().padLeft(2, '0');
          await database.insert('operation_projection', <String, Object?>{
            ...keyColumns,
            'operation_id': 'ack-index-operation-$source-$suffix',
            'revision': 1,
            'state': 'queued',
            'is_terminal': 0,
            'value_json': '{}',
            'value_digest': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'is_active': 1,
            'gc_eligible': 0,
            'snapshot_marker': source,
            'source_projection_id': source,
          });
          await database.insert('queue_entry_projection', <String, Object?>{
            ...keyColumns,
            'queue_entry_id': 'ack-index-queue-$source-$suffix',
            'operation_id': null,
            'revision': 1,
            'position': index,
            'state': 'queued',
            'value_json': '{}',
            'value_digest': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'is_active': 1,
            'gc_eligible': 0,
            'snapshot_marker': source,
            'source_projection_id': source,
          });
          await database.insert('interaction_projection', <String, Object?>{
            ...keyColumns,
            'interaction_id': 'ack-index-interaction-$source-$suffix',
            'revision': 1,
            'kind': 'question',
            'state': 'pending',
            'claim_actor_id': null,
            'claim_expires_at': null,
            'value_json': '{}',
            'value_digest': 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            'is_active': 1,
            'gc_eligible': 0,
            'snapshot_marker': source,
            'source_projection_id': source,
          });
        }
      }
      await database.close();

      expect(
        await repository.acknowledgePublication(a.publicationEventId!),
        isTrue,
      );
      final after = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      for (final table in const <String>[
        'operation_projection',
        'queue_entry_projection',
        'interaction_projection',
      ]) {
        final aRows = await after.rawQuery(
          'SELECT COUNT(*) AS row_count FROM $table WHERE source_projection_id = ? AND gc_eligible <> 1',
          const <Object?>[sourceA],
        );
        final bRows = await after.rawQuery(
          'SELECT COUNT(*) AS row_count FROM $table WHERE source_projection_id = ? AND gc_eligible <> 0',
          const <Object?>[sourceB],
        );
        expect(aRows.single['row_count'], 0, reason: table);
        expect(bRows.single['row_count'], 0, reason: table);
      }
      expect(
        (await after.query(
          'projection_inbox',
          columns: const <String>['gc_eligible'],
          where: 'projection_id = ?',
          whereArgs: const <Object?>[sourceA],
        )).single['gc_eligible'],
        1,
      );
      expect(
        (await after.query(
          'projection_inbox',
          columns: const <String>['gc_eligible'],
          where: 'projection_id = ?',
          whereArgs: const <Object?>[sourceB],
        )).single['gc_eligible'],
        0,
      );
      await after.close();
      await subscription.cancel();
    });

    test('pressure GC skips protected prefixes and retains the current inbox', () async {
      const currentProjectionId = 'gc-progress-current';
      final current = _projection(
        currentProjectionId,
        revision: 1,
        operation: 'gc-progress-current-operation',
      );
      await repository.commitRuntimeProjections(current);
      final databasePath = repository.resolvedDatabasePath!;
      await repository.close();

      final database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      final keyColumns = <String, Object?>{
        'bridge_identity_id': key.partition.bridgeIdentityId,
        'bridge_instance_id': key.partition.bridgeInstanceId,
        'codex_source_id': key.partition.codexSourceId,
        'provider_thread_id': key.providerThreadId,
      };
      for (var index = 0; index < 40; index += 1) {
        final suffix = index.toString().padLeft(2, '0');
        await database.insert('projection_inbox', <String, Object?>{
          ...keyColumns,
          'projection_id': 'gc-protected-inbox-$suffix',
          'connection_epoch': 'connection-1',
          'source_epoch': 'source-1',
          'provider_instance_epoch': 'provider-1',
          'runtime_authority_generation': 1,
          'source_revision': 1,
          'projection_digest': _evidenceDigest,
          'payload_json': '{}',
          'state': 'applied',
          'gc_eligible': 0,
          'admitted_at': index,
        });
        await database.insert('operation_projection', <String, Object?>{
          ...keyColumns,
          'operation_id': 'gc-protected-operation-$suffix',
          'revision': 1,
          'state': 'queued',
          'is_terminal': 0,
          'value_json': '{}',
          'value_digest': _resultDigest,
          'is_active': 1,
          'gc_eligible': 0,
          'snapshot_marker': 'a-protected-$suffix',
          'source_projection_id': currentProjectionId,
        });
      }
      await database.insert('projection_inbox', <String, Object?>{
        ...keyColumns,
        'projection_id': 'gc-eligible-inbox',
        'connection_epoch': 'connection-1',
        'source_epoch': 'source-1',
        'provider_instance_epoch': 'provider-1',
        'runtime_authority_generation': 1,
        'source_revision': 1,
        'projection_digest': _evidenceDigest,
        'payload_json': '{}',
        'state': 'stale',
        'gc_eligible': 1,
        'admitted_at': 100,
      });
      await database.insert('operation_projection', <String, Object?>{
        ...keyColumns,
        'operation_id': 'gc-eligible-operation',
        'revision': 1,
        'state': 'queued',
        'is_terminal': 0,
        'value_json': '{}',
        'value_digest': _resultDigest,
        'is_active': 1,
        'gc_eligible': 1,
        'snapshot_marker': 'z-eligible',
        'source_projection_id': 'gc-eligible-inbox',
      });
      final entryCount =
          (await database.query(
                'replica_usage',
                columns: const <String>['entry_count'],
                where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
                whereArgs: <Object?>[
                  key.partition.bridgeIdentityId,
                  key.partition.bridgeInstanceId,
                  key.partition.codexSourceId,
                  key.providerThreadId,
                ],
              )).single['entry_count']!
              as int;
      await database.close();

      repository = await _openRepository(
        tempDirectory,
        maxEntriesPerThread: entryCount - 2,
      );
      final duplicate = await repository.commitRuntimeProjections(current);
      expect(duplicate.wasDuplicate, isTrue);

      final after = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      Future<List<Map<String, Object?>>> rows(
        String table,
        String predicate,
        List<Object?> predicateArgs,
      ) => after.query(
        table,
        where:
            'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND $predicate',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
          ...predicateArgs,
        ],
      );

      expect(
        await rows('projection_inbox', 'projection_id = ?', <Object?>[
          'gc-eligible-inbox',
        ]),
        isEmpty,
      );
      expect(
        await rows('operation_projection', 'operation_id = ?', <Object?>[
          'gc-eligible-operation',
        ]),
        isEmpty,
      );
      expect(
        await rows('projection_inbox', 'projection_id LIKE ?', const <Object?>[
          'gc-protected-inbox-%',
        ]),
        hasLength(40),
      );
      expect(
        await rows(
          'operation_projection',
          'operation_id LIKE ?',
          const <Object?>['gc-protected-operation-%'],
        ),
        hasLength(40),
      );
      expect(
        await rows('projection_inbox', 'projection_id = ?', const <Object?>[
          currentProjectionId,
        ]),
        hasLength(1),
      );
      await after.close();
    });

    test('pressure GC retains the exact current envelope among duplicate revisions', () async {
      final publicationSubscription = repository.updates.listen((_) {});
      Future<void> commitMaterialization(
        MaterializationBegin begin,
        CanonicalItem item,
      ) async {
        final body = MaterializationPageBody(items: [item]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(begin);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        final receipt = await repository.commitMaterialization(
          _commit(begin, digest, repository),
        );
        final eventId = receipt.publicationEventId;
        expect(eventId, isNotNull);
        expect(await repository.acknowledgePublication(eventId!), isTrue);
      }

      for (var index = 0; index < 40; index += 1) {
        await commitMaterialization(
          _begin(
            'duplicate-fence-${index.toString().padLeft(2, '0')}',
            revision: 1,
            totalItems: 1,
            lower: 1,
            upper: 1,
          ),
          _item(1, text: 'duplicate-$index'),
        );
      }

      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      final currentRows = await database.query(
        'thread_state',
        columns: const <String>[
          'current_envelope_id',
          'current_envelope_digest',
        ],
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      );
      final currentId = currentRows.single['current_envelope_id']! as String;
      final currentDigest =
          currentRows.single['current_envelope_digest']! as String;
      expect(currentId, 'duplicate-fence-39');
      await database.update(
        'committed_envelope',
        const <String, Object?>{'committed_at': 0},
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
          'source-1',
          'provider-1',
          'duplicate-fence-00',
        ],
      );
      await database.close();

      await repository.close();
      repository = await _openRepository(
        tempDirectory,
        maxEntriesPerThread: 20,
      );
      await repository.commitRuntimeProjections(
        _projection(
          'duplicate-gc-trigger-1',
          revision: 2,
          operation: 'duplicate-gc-op-1',
        ),
      );
      await repository.commitRuntimeProjections(
        _projection(
          'duplicate-gc-trigger-2',
          revision: 3,
          operation: 'duplicate-gc-op-2',
        ),
      );

      final inspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final bound = await inspection.query(
        'committed_envelope',
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
          'source-1',
          'provider-1',
          currentId,
        ],
      );
      expect(bound, hasLength(1));
      expect(bound.single['envelope_digest'], currentDigest);
      final countRows = await inspection.rawQuery(
        'SELECT COUNT(*) AS count FROM committed_envelope WHERE bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      );
      expect(countRows.single['count'], 1);
      await inspection.close();
      await publicationSubscription.cancel();
    });

    test(
      'superseded projection GC uses envelope provenance rather than row id',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'provenance-envelope',
            revision: 1,
            operation: 'provenance-row',
          ),
        );
        await repository.commitRuntimeProjections(
          _projection(
            'provenance-replacement',
            revision: 2,
            operation: 'provenance-visible-row',
            complete: true,
          ),
        );
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          maxEntriesPerThread: 1,
        );
        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'provenance-pressure-trigger',
              revision: 3,
              operation: 'provenance-trigger-row',
            ),
          ),
          _failure(RepositoryFailureCode.capacityExceeded),
        );
        final database = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final key = _key();
        final hidden = await database.query(
          'operation_projection',
          columns: const <String>[
            'operation_id',
            'source_projection_id',
            'snapshot_marker',
          ],
          where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND operation_id = ?',
          whereArgs: <Object?>[
            key.partition.bridgeIdentityId,
            key.partition.bridgeInstanceId,
            key.partition.codexSourceId,
            key.providerThreadId,
            'provenance-row',
          ],
        );
        expect(hidden, hasLength(1));
        expect(hidden.single['source_projection_id'], 'provenance-envelope');
        expect(
          hidden.single['snapshot_marker'],
          isNot('provenance-replacement'),
        );
        await database.close();
      },
    );

    test('pressure GC retains exact last-good and current rows across connection rollover', () async {
      final publicationSubscription = repository.updates.listen((_) {});
      Future<void> commitMaterialization(
        MaterializationBegin begin,
        MaterializationPageBody body,
      ) async {
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(begin);
        await repository.stageMaterializationPage(
          _page(begin, body, digest: digest),
        );
        final receipt = await repository.commitMaterialization(
          _commit(begin, digest, repository),
        );
        final eventId = receipt.publicationEventId;
        expect(eventId, isNotNull);
        expect(await repository.acknowledgePublication(eventId!), isTrue);
      }

      for (var index = 0; index < 40; index += 1) {
        await commitMaterialization(
          _begin(
            'rollover-old-${index.toString().padLeft(2, '0')}',
            revision: 1,
            totalItems: 1,
            lower: 1,
            upper: 1,
          ),
          MaterializationPageBody(items: [_item(1, text: 'old-$index')]),
        );
      }
      final weak = _begin(
        'rollover-weak-current',
        revision: 1,
        totalItems: 1,
        connectionEpoch: 'connection-2',
        health: ReadHealth.degraded,
        problemCode: 'connection-rollover-partial',
        isSnapshot: false,
        structural: StructuralCoverage.partial,
        lower: 1,
        upper: 99,
      );
      await commitMaterialization(
        weak,
        MaterializationPageBody(
          items: [_item(1, text: 'weak')],
          gaps: [
            TypedGap(
              gapId: 'weak-gap',
              kind: GapKind.ordinal,
              startOrdinal: 99,
              endOrdinal: 99,
            ),
          ],
        ),
      );

      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      final state = (await database.query(
        'thread_state',
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      )).single;
      final currentId = state['current_envelope_id']! as String;
      final currentDigest = state['current_envelope_digest']! as String;
      final lastGoodId = state['last_good_envelope_id']! as String;
      final lastGoodDigest = state['last_good_envelope_digest']! as String;
      expect(currentId, 'rollover-weak-current');
      expect(lastGoodId, 'rollover-old-39');
      await database.update(
        'committed_envelope',
        const <String, Object?>{'committed_at': 0},
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
          'source-1',
          'provider-1',
          'rollover-old-00',
        ],
      );
      await database.close();

      await repository.close();
      repository = await _openRepository(
        tempDirectory,
        maxEntriesPerThread: 20,
      );
      await repository.commitRuntimeProjections(
        _projection(
          'rollover-gc-trigger-1',
          revision: 2,
          operation: 'rollover-gc-op-1',
          connectionEpoch: 'connection-2',
        ),
      );
      await repository.commitRuntimeProjections(
        _projection(
          'rollover-gc-trigger-2',
          revision: 3,
          operation: 'rollover-gc-op-2',
          connectionEpoch: 'connection-2',
        ),
      );

      final inspection = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      Future<List<Map<String, Object?>>> readEnvelope(String id) {
        return inspection.query(
          'committed_envelope',
          where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
          whereArgs: <Object?>[
            key.partition.bridgeIdentityId,
            key.partition.bridgeInstanceId,
            key.partition.codexSourceId,
            key.providerThreadId,
            'source-1',
            'provider-1',
            id,
          ],
        );
      }

      final current = await inspection.query(
        'committed_envelope',
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
          'source-1',
          'provider-1',
          currentId,
        ],
      );
      final lastGood = await readEnvelope(lastGoodId);
      expect(current, hasLength(1));
      expect(current.single['envelope_digest'], currentDigest);
      expect(lastGood, hasLength(1));
      expect(lastGood.single['envelope_digest'], lastGoodDigest);
      final stateAfter = (await inspection.query(
        'thread_state',
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      )).single;
      expect(stateAfter['current_envelope_id'], currentId);
      expect(stateAfter['current_envelope_digest'], currentDigest);
      await inspection.close();
      await publicationSubscription.cancel();
    });

    test(
      'readback rejects a partially populated thread-state binding',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'binding-seed',
            revision: 1,
            operation: 'binding-operation',
          ),
        );
        final database = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await database.execute('PRAGMA ignore_check_constraints = ON');
        final key = _key();
        await database.update(
          'thread_state',
          const <String, Object?>{'current_envelope_id': 'orphan-envelope'},
          where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
          whereArgs: <Object?>[
            key.partition.bridgeIdentityId,
            key.partition.bridgeInstanceId,
            key.partition.codexSourceId,
            key.providerThreadId,
          ],
        );
        await database.close();
        await expectLater(
          repository.readWindow(key),
          _failure(RepositoryFailureCode.invalidDatabaseIdentity),
        );
      },
    );

    test(
      'canonical thread state cannot silently become an unbound both-null head',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'canonical-binding-seed',
            revision: 1,
            operation: 'binding-operation',
          ),
        );
        final database = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await database.execute('PRAGMA ignore_check_constraints = ON');
        final key = _key();
        await database.update(
          'thread_state',
          const <String, Object?>{
            'state_kind': 'canonical',
            'current_envelope_id': null,
            'current_envelope_digest': null,
          },
          where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
          whereArgs: <Object?>[
            key.partition.bridgeIdentityId,
            key.partition.bridgeInstanceId,
            key.partition.codexSourceId,
            key.providerThreadId,
          ],
        );
        await database.close();
        await expectLater(
          repository.readWindow(key),
          _failure(RepositoryFailureCode.invalidDatabaseIdentity),
        );
      },
    );

    test('readback rejects a missing bound envelope proof row', () async {
      final begin = _begin('binding-proof-seed', revision: 1, totalItems: 1);
      final body = MaterializationPageBody(items: [_item(1)]);
      final digest = repository.materializationPageDigest(body);
      await repository.beginMaterialization(begin);
      await repository.stageMaterializationPage(
        _page(begin, body, digest: digest),
      );
      await repository.commitMaterialization(
        _commit(begin, digest, repository),
      );

      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      await database.delete(
        'committed_envelope',
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
          'source-1',
          'provider-1',
          begin.materializationId,
        ],
      );
      await database.close();
      await expectLater(
        repository.readWindow(key),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test(
      'projection epoch must match the canonical source/provider epoch',
      () async {
        final first = _begin(
          'projection-canonical-epoch',
          revision: 1,
          totalItems: 1,
        );
        final body = MaterializationPageBody(items: [_item(1)]);
        final digest = repository.materializationPageDigest(body);
        await repository.beginMaterialization(first);
        await repository.stageMaterializationPage(
          _page(first, body, digest: digest),
        );
        await repository.commitMaterialization(
          _commit(first, digest, repository),
        );
        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'projection-wrong-canonical-epoch',
              revision: 2,
              operation: 'wrong-epoch',
              sourceEpoch: 'source-2',
            ),
          ),
          _failure(RepositoryFailureCode.staleEpoch),
        );
        expect((await repository.readWindow(_key())).operations, isEmpty);
      },
    );

    test(
      'same generation and revision with another projection id conflicts',
      () async {
        await repository.commitRuntimeProjections(
          _projection('projection-same-head-a', revision: 1, operation: 'op-a'),
        );
        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'projection-same-head-b',
              revision: 1,
              operation: 'op-b',
            ),
          ),
          _failure(RepositoryFailureCode.identityConflict),
        );
        expect(
          (await repository.readWindow(_key())).operations.single.operationId,
          'op-a',
        );
      },
    );

    test('pressure GC supports a projection-only thread state', () async {
      await repository.close();
      repository = await _openRepository(
        tempDirectory,
        maxEntriesPerThread: 48,
      );
      final publicationSubscription = repository.updates.listen((_) {});
      for (var index = 0; index < 24; index += 1) {
        final receipt = await repository.commitRuntimeProjections(
          _projection(
            'projection-only-gc-$index',
            revision: index + 1,
            operation: 'projection-only-op',
          ),
        );
        final eventId = receipt.publicationEventId;
        expect(eventId, isNotNull);
        expect(await repository.acknowledgePublication(eventId!), isTrue);
      }
      final window = await repository.readWindow(_key());
      expect(window.operations.single.operationId, 'projection-only-op');
      await publicationSubscription.cancel();
    });

    test(
      'pressure GC commits two bounded batches before a mutation can fail',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'gc-batch-seed',
            revision: 1,
            operation: 'gc-seed-operation',
          ),
        );
        await repository.close();
        final inspection = await databaseFactoryFfi.openDatabase(
          path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final key = _key();
        for (var index = 0; index < 160; index += 1) {
          await inspection.insert('operation_projection', <String, Object?>{
            ...<String, Object?>{
              'bridge_identity_id': key.partition.bridgeIdentityId,
              'bridge_instance_id': key.partition.bridgeInstanceId,
              'codex_source_id': key.partition.codexSourceId,
              'provider_thread_id': key.providerThreadId,
            },
            'operation_id': 'gc-stale-${index.toString().padLeft(3, '0')}',
            'revision': 1,
            'state': 'queued',
            'is_terminal': 0,
            'value_json': '{}',
            'value_digest': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            'is_active': 0,
            'gc_eligible': 0,
            'snapshot_marker': '',
            'source_projection_id': '',
          });
        }
        await inspection.close();

        repository = await _openRepository(
          tempDirectory,
          maxEntriesPerThread: 110,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterInboxAdmission) {
              throw StateError('simulated mutation rollback after GC');
            }
          },
        );
        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'gc-batch-trigger',
              revision: 2,
              operation: 'gc-trigger-operation',
            ),
          ),
          throwsStateError,
        );
        final after = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final staleRows = await after.query(
          'operation_projection',
          columns: const <String>['operation_id'],
          where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND is_active = 0',
          whereArgs: <Object?>[
            key.partition.bridgeIdentityId,
            key.partition.bridgeInstanceId,
            key.partition.codexSourceId,
            key.providerThreadId,
          ],
        );
        expect(staleRows, hasLength(96));
        expect(
          await after.query(
            'projection_inbox',
            where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND projection_id = ?',
            whereArgs: <Object?>[
              key.partition.bridgeIdentityId,
              key.partition.bridgeInstanceId,
              key.partition.codexSourceId,
              key.providerThreadId,
              'gc-batch-trigger',
            ],
          ),
          hasLength(1),
        );
        await after.close();
      },
    );

    test(
      'projection publication outbox recovers after readback crash',
      () async {
        var crashAfterReadback = true;
        await repository.close();
        repository = await _openRepository(
          tempDirectory,
          faultHook: (stage, _) async {
            if (stage == RepositoryFaultStage.afterReadback &&
                crashAfterReadback) {
              crashAfterReadback = false;
              throw StateError('simulated crash before projection publication');
            }
          },
        );
        final projection = _projection(
          'projection-publication-recovery',
          revision: 1,
          operation: 'op-publication-recovery',
        );
        await expectLater(
          repository.commitRuntimeProjections(projection),
          throwsStateError,
        );
        final inspection = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          (await inspection.query(
            'publication_outbox',
            columns: const <String>['phase'],
          )).single['phase'],
          'applied',
        );
        await inspection.close();
        final retry = await repository.commitRuntimeProjections(projection);
        expect(retry.wasDuplicate, isTrue);
        expect(retry.wasPublished, isTrue);
        expect(
          retry.window.operations.single.operationId,
          'op-publication-recovery',
        );
      },
    );

    test(
      'projection publication emits one update for one applied identity',
      () async {
        final updates = <RepositoryWindow>[];
        final subscription = repository.updates.listen(updates.add);
        final projection = _projection(
          'projection-single-publication',
          revision: 1,
          operation: 'op-single-publication',
        );
        final first = await repository.commitRuntimeProjections(projection);
        expect(updates, hasLength(1));
        expect(first.publicationEventId, updates.single.publicationEventId);
        expect(
          await repository.acknowledgePublication(first.publicationEventId!),
          isTrue,
        );
        final duplicate = await repository.commitRuntimeProjections(projection);
        expect(duplicate.wasDuplicate, isTrue);
        expect(duplicate.wasPublished, isFalse);
        expect(updates, hasLength(1));
        await subscription.cancel();
      },
    );

    test(
      'complete snapshot omission can reactivate a same-revision row',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'projection-reactivate-seed',
            revision: 1,
            operation: 'op',
            operationText: 'same',
          ),
        );
        await repository.commitRuntimeProjections(
          _projection(
            'projection-reactivate-omit',
            revision: 2,
            operation: null,
            complete: true,
          ),
        );
        expect((await repository.readWindow(_key())).operations, isEmpty);
        final reactivated = await repository.commitRuntimeProjections(
          _projection(
            'projection-reactivate-restore',
            revision: 3,
            operation: 'op',
            operationText: 'same',
            operationRevision: 1,
          ),
        );
        expect(reactivated.window.operations.single.operationId, 'op');
      },
    );

    test(
      'complete snapshot uses a marker without scanning large active history',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'large-history-seed',
            revision: 1,
            operation: 'large-history-seed-operation',
          ),
        );
        await repository.close();
        final database = await databaseFactoryFfi.openDatabase(
          path.join(
            tempDirectory.path,
            ConversationRepository.defaultDatabaseName,
          ),
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final key = _key();
        for (var index = 0; index < 2000; index += 1) {
          await database.insert('operation_projection', <String, Object?>{
            ...<String, Object?>{
              'bridge_identity_id': key.partition.bridgeIdentityId,
              'bridge_instance_id': key.partition.bridgeInstanceId,
              'codex_source_id': key.partition.codexSourceId,
              'provider_thread_id': key.providerThreadId,
            },
            'operation_id': 'large-history-${index.toString().padLeft(4, '0')}',
            'revision': 1,
            'state': 'queued',
            'is_terminal': 0,
            'value_json': '{}',
            'value_digest': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            'is_active': 1,
            'gc_eligible': 0,
            'snapshot_marker': '',
            'source_projection_id': '',
          });
        }
        await database.close();
        repository = await _openRepository(tempDirectory);
        final receipt = await repository.commitRuntimeProjections(
          _projection(
            'large-history-complete',
            revision: 2,
            operation: null,
            complete: true,
          ),
        );
        expect(receipt.window.operations, isEmpty);
        final after = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          await after.query(
            'operation_projection',
            columns: const <String>['operation_id'],
            where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ? AND snapshot_marker = ?',
            whereArgs: <Object?>[
              key.partition.bridgeIdentityId,
              key.partition.bridgeInstanceId,
              key.partition.codexSourceId,
              key.providerThreadId,
              '',
            ],
          ),
          hasLength(2001),
        );
        expect(
          (await after.query(
            'projection_head',
            columns: const <String>['operation_snapshot_marker'],
            where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
            whereArgs: <Object?>[
              key.partition.bridgeIdentityId,
              key.partition.bridgeInstanceId,
              key.partition.codexSourceId,
              key.providerThreadId,
            ],
          )).single['operation_snapshot_marker'],
          'large-history-complete',
        );
        await after.close();
      },
    );

    test('self-referential public JSON fails before freezing', () {
      final value = <String, Object?>{};
      value['self'] = value;
      expect(
        () => CanonicalItem(
          providerTurnId: 'turn',
          providerItemId: 'item',
          turnOrdinal: 0,
          itemOrdinal: 0,
          timelineOrdinal: 0,
          kind: 'text',
          normalizedPayload: value,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('deep public JSON fails before recursive freezing', () {
      Object value = 'leaf';
      for (
        var index = 0;
        index < ConversationRepository.maxJsonDepth + 2;
        index += 1
      ) {
        value = <String, Object?>{'nested': value};
      }
      expect(
        () => CanonicalItem(
          providerTurnId: 'turn',
          providerItemId: 'item',
          turnOrdinal: 0,
          itemOrdinal: 0,
          timelineOrdinal: 0,
          kind: 'text',
          normalizedPayload: <String, Object?>{'root': value},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('large public JSON node count fails before recursive freezing', () {
      final values = List<Object?>.filled(
        ConversationRepository.maxJsonNodes + 1,
        1,
        growable: false,
      );
      expect(
        () => CanonicalItem(
          providerTurnId: 'turn',
          providerItemId: 'item',
          turnOrdinal: 0,
          itemOrdinal: 0,
          timelineOrdinal: 0,
          kind: 'text',
          normalizedPayload: <String, Object?>{'values': values},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('nested public JSON UTF-8 bytes fail before recursive freezing', () {
      final large = '界' * 3000000;
      expect(
        () => CanonicalItem(
          providerTurnId: 'turn',
          providerItemId: 'item',
          turnOrdinal: 0,
          itemOrdinal: 0,
          timelineOrdinal: 0,
          kind: 'text',
          normalizedPayload: <String, Object?>{
            'outer': <String, Object?>{'inner': large},
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('capacity includes staging rows and rejects before commit', () async {
      await repository.close();
      repository = ConversationRepository.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: path.join(tempDirectory.path, 'bounded.db'),
        contractMapper: const _FixtureContract(),
        maxEntriesPerThread: 1,
      );
      await repository.open();
      final first = _begin('capacity-first', revision: 1, totalItems: 1);
      final body = MaterializationPageBody(items: [_item(1)]);
      final digest = repository.materializationPageDigest(body);
      await repository.beginMaterialization(first);
      await expectLater(
        repository.stageMaterializationPage(_page(first, body, digest: digest)),
        _failure(RepositoryFailureCode.capacityExceeded),
      );
      expect((await repository.readWindow(_key())).lastGoodRevision, -1);
    });

    test(
      'capacity includes full projection and inbox payload columns',
      () async {
        await repository.close();
        repository = ConversationRepository.forTesting(
          databaseFactory: databaseFactoryFfi,
          databasePath: path.join(tempDirectory.path, 'projection-bounded.db'),
          contractMapper: const _FixtureContract(),
          maxBytesPerThread: 2048,
        );
        await repository.open();
        final projection = _projection(
          'projection-capacity',
          revision: 1,
          operation: 'op-capacity',
          operationText: List<String>.filled(4096, 'x').join(),
        );
        await expectLater(
          repository.commitRuntimeProjections(projection),
          _failure(RepositoryFailureCode.capacityExceeded),
        );
        expect((await repository.readWindow(_key())).operations, isEmpty);
      },
    );

    test('replica usage undercount fails closed before mutation', () async {
      await repository.commitRuntimeProjections(
        _projection(
          'usage-guard-seed',
          revision: 1,
          operation: 'usage-guard-operation',
        ),
      );
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      await database.update(
        'replica_usage',
        const <String, Object?>{'entry_count': 0, 'byte_count': 0},
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      );
      await database.close();
      await expectLater(
        repository.commitRuntimeProjections(
          _projection(
            'usage-guard-follow-up',
            revision: 2,
            operation: 'usage-guard-follow-up-operation',
          ),
        ),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('missing replica usage row fails closed before mutation', () async {
      await repository.commitRuntimeProjections(
        _projection(
          'usage-missing-seed',
          revision: 1,
          operation: 'usage-missing-operation',
        ),
      );
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      await database.delete(
        'replica_usage',
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      );
      await database.close();
      await expectLater(
        repository.commitRuntimeProjections(
          _projection(
            'usage-missing-follow-up',
            revision: 2,
            operation: 'usage-missing-follow-up-operation',
          ),
        ),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('replica usage guard detects coordinated counter tampering', () async {
      await repository.commitRuntimeProjections(
        _projection(
          'usage-double-guard-seed',
          revision: 1,
          operation: 'usage-double-guard-operation',
        ),
      );
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      await database.update(
        'replica_usage',
        const <String, Object?>{
          'entry_count': 0,
          'byte_count': 0,
          'guard_entry_count': 0,
          'guard_byte_count': 0,
        },
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      );
      await database.close();
      await expectLater(
        repository.commitRuntimeProjections(
          _projection(
            'usage-double-guard-follow-up',
            revision: 2,
            operation: 'usage-double-guard-follow-up-operation',
          ),
        ),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test(
      'independent usage audit rejects offset-preserving counter tampering',
      () async {
        await repository.commitRuntimeProjections(
          _projection(
            'usage-offset-seed',
            revision: 1,
            operation: 'usage-offset-operation',
          ),
        );
        final database = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final key = _key();
        final usage = (await database.query(
          'replica_usage',
          columns: const <String>[
            'entry_count',
            'byte_count',
            'guard_entry_count',
            'guard_byte_count',
          ],
          where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
          whereArgs: <Object?>[
            key.partition.bridgeIdentityId,
            key.partition.bridgeInstanceId,
            key.partition.codexSourceId,
            key.providerThreadId,
          ],
        )).single;
        final entries = usage['entry_count']! as int;
        final bytes = usage['byte_count']! as int;
        final entryOffset = (usage['guard_entry_count']! as int) - entries;
        final byteOffset = (usage['guard_byte_count']! as int) - bytes;
        await database.update(
          'replica_usage',
          <String, Object?>{
            'entry_count': 0,
            'byte_count': 0,
            'guard_entry_count': entryOffset,
            'guard_byte_count': byteOffset,
          },
          where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
          whereArgs: <Object?>[
            key.partition.bridgeIdentityId,
            key.partition.bridgeInstanceId,
            key.partition.codexSourceId,
            key.providerThreadId,
          ],
        );
        await database.close();
        await expectLater(
          repository.commitRuntimeProjections(
            _projection(
              'usage-offset-follow-up',
              revision: 2,
              operation: 'usage-offset-follow-up-operation',
            ),
          ),
          _failure(RepositoryFailureCode.invalidDatabaseIdentity),
        );
      },
    );

    test(
      'SQLite data_version changes only for another connection commit',
      () async {
        await repository.close();
        final owner = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final other = await databaseFactoryFfi.openDatabase(
          repository.resolvedDatabasePath!,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final metadata = (await owner.query('replica_metadata')).single;
        final originalVersion = metadata['schema_version']! as int;
        final baseline = (await owner.rawQuery('PRAGMA data_version'))
            .single['data_version'];
        await owner.update(
          'replica_metadata',
          <String, Object?>{'schema_version': originalVersion + 1},
          where: 'schema_identity = ?',
          whereArgs: <Object?>[metadata['schema_identity']],
        );
        final afterOwnerCommit = (await owner.rawQuery('PRAGMA data_version'))
            .single['data_version'];
        expect(afterOwnerCommit, baseline);
        await other.update(
          'replica_metadata',
          <String, Object?>{'schema_version': originalVersion + 2},
          where: 'schema_identity = ?',
          whereArgs: <Object?>[metadata['schema_identity']],
        );
        final afterOtherCommit = (await owner.rawQuery('PRAGMA data_version'))
            .single['data_version'];
        expect(afterOtherCommit, isNot(afterOwnerCommit));
        await other.update(
          'replica_metadata',
          <String, Object?>{'schema_version': originalVersion},
          where: 'schema_identity = ?',
          whereArgs: <Object?>[metadata['schema_identity']],
        );
        await other.close();
        await owner.close();
      },
    );

    test('independent usage recompute rejects coordinated counters before reopen', () async {
      await repository.commitRuntimeProjections(
        _projection(
          'usage-coordinated-preopen-seed',
          revision: 1,
          operation: 'usage-coordinated-preopen-operation',
        ),
      );
      final databasePath = repository.resolvedDatabasePath!;
      await repository.close();
      final database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      final usage = (await database.query(
        'replica_usage',
        columns: const <String>[
          'entry_count',
          'byte_count',
          'guard_entry_count',
          'guard_byte_count',
        ],
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      )).single;
      final entryOffset =
          (usage['guard_entry_count']! as int) - (usage['entry_count']! as int);
      final byteOffset =
          (usage['guard_byte_count']! as int) - (usage['byte_count']! as int);
      final where =
          'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?';
      final whereArgs = <Object?>[
        key.partition.bridgeIdentityId,
        key.partition.bridgeInstanceId,
        key.partition.codexSourceId,
        key.providerThreadId,
      ];
      await database.update(
        'replica_usage',
        <String, Object?>{
          'entry_count': 0,
          'byte_count': 0,
          'guard_entry_count': entryOffset,
          'guard_byte_count': byteOffset,
        },
        where: where,
        whereArgs: whereArgs,
      );
      await database.update(
        'replica_usage_audit',
        const <String, Object?>{'entry_count': 0, 'byte_count': 0},
        where: where,
        whereArgs: whereArgs,
      );
      await database.close();
      repository = await _openRepository(tempDirectory);
      await expectLater(
        repository.commitRuntimeProjections(
          _projection(
            'usage-coordinated-preopen-follow-up',
            revision: 2,
            operation: 'usage-coordinated-preopen-follow-up-operation',
          ),
        ),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });

    test('external coordinated usage tamper invalidates the live verification cache', () async {
      await repository.commitRuntimeProjections(
        _projection(
          'usage-coordinated-live-seed',
          revision: 1,
          operation: 'usage-coordinated-live-operation',
        ),
      );
      final database = await databaseFactoryFfi.openDatabase(
        repository.resolvedDatabasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final key = _key();
      final usage = (await database.query(
        'replica_usage',
        columns: const <String>[
          'entry_count',
          'byte_count',
          'guard_entry_count',
          'guard_byte_count',
        ],
        where: 'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?',
        whereArgs: <Object?>[
          key.partition.bridgeIdentityId,
          key.partition.bridgeInstanceId,
          key.partition.codexSourceId,
          key.providerThreadId,
        ],
      )).single;
      final entryOffset =
          (usage['guard_entry_count']! as int) - (usage['entry_count']! as int);
      final byteOffset =
          (usage['guard_byte_count']! as int) - (usage['byte_count']! as int);
      final where =
          'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?';
      final whereArgs = <Object?>[
        key.partition.bridgeIdentityId,
        key.partition.bridgeInstanceId,
        key.partition.codexSourceId,
        key.providerThreadId,
      ];
      await database.update(
        'replica_usage',
        <String, Object?>{
          'entry_count': 0,
          'byte_count': 0,
          'guard_entry_count': entryOffset,
          'guard_byte_count': byteOffset,
        },
        where: where,
        whereArgs: whereArgs,
      );
      await database.update(
        'replica_usage_audit',
        const <String, Object?>{'entry_count': 0, 'byte_count': 0},
        where: where,
        whereArgs: whereArgs,
      );
      await database.close();
      await expectLater(
        repository.commitRuntimeProjections(
          _projection(
            'usage-coordinated-live-follow-up',
            revision: 2,
            operation: 'usage-coordinated-live-follow-up-operation',
          ),
        ),
        _failure(RepositoryFailureCode.invalidDatabaseIdentity),
      );
    });
  });
}

Future<void> _samePidLeaseCompetingIsolate(List<Object?> arguments) async {
  final sendPort = arguments[0]! as SendPort;
  final databasePath = arguments[1]! as String;
  var result = 'error:competing isolate did not run';
  try {
    sqfliteFfiInit();
    final contender = ConversationRepository.forTesting(
      databaseFactory: databaseFactoryFfi,
      databasePath: databasePath,
      contractMapper: const _FixtureContract(),
    );
    try {
      await contender.open();
      result = 'opened';
    } on ConversationRepositoryException catch (error) {
      result = 'failure:${error.code.name}';
    } finally {
      await contender.close();
    }
  } catch (error) {
    result = 'error:$error';
  }
  sendPort.send(result);
}

Future<void> _createLegacyV7Database(String databasePath, String marker) async {
  final database = await databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 7,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE replica_metadata (
            schema_identity TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL
          ) STRICT
        ''');
        await db.insert('replica_metadata', const <String, Object?>{
          'schema_identity': 'ccpocket.conversation_replica_v7',
          'schema_version': 7,
        });
        await db.execute(
          'CREATE TABLE legacy_v7_marker (value TEXT NOT NULL) STRICT',
        );
        await db.insert('legacy_v7_marker', <String, Object?>{'value': marker});
      },
    ),
  );
  await database.execute('PRAGMA user_version = 7');
  await database.close();
}

Future<void> _createLegacyV6Database(String databasePath, String marker) async {
  final database = await databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 6,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE replica_metadata (
            schema_identity TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL
          ) STRICT
        ''');
        await db.insert('replica_metadata', const <String, Object?>{
          'schema_identity': 'ccpocket.conversation_replica_v6',
          'schema_version': 6,
        });
        await db.execute(
          'CREATE TABLE legacy_v6_marker (value TEXT NOT NULL) STRICT',
        );
        await db.insert('legacy_v6_marker', <String, Object?>{'value': marker});
      },
    ),
  );
  await database.execute('PRAGMA user_version = 6');
  await database.close();
}

Future<void> _createLegacyV5Database(String databasePath, String marker) async {
  final database = await databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 5,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE replica_metadata (
            schema_identity TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL
          ) STRICT
        ''');
        await db.insert('replica_metadata', const <String, Object?>{
          'schema_identity': 'ccpocket.conversation_replica_v5',
          'schema_version': 5,
        });
        await db.execute(
          'CREATE TABLE legacy_v5_marker (value TEXT NOT NULL) STRICT',
        );
        await db.insert('legacy_v5_marker', <String, Object?>{'value': marker});
        await db.execute('''
          CREATE TABLE projection_inbox (
            bridge_identity_id TEXT NOT NULL,
            bridge_instance_id TEXT NOT NULL,
            codex_source_id TEXT NOT NULL,
            provider_thread_id TEXT NOT NULL,
            admitted_at INTEGER NOT NULL,
            projection_id TEXT NOT NULL,
            state TEXT NOT NULL
          ) STRICT
        ''');
        await db.execute('''
          CREATE INDEX projection_inbox_gc_idx ON projection_inbox (
            bridge_identity_id,
            bridge_instance_id,
            codex_source_id,
            provider_thread_id,
            admitted_at,
            projection_id,
            state
          )
        ''');
      },
    ),
  );
  await database.execute('PRAGMA user_version = 5');
  await database.close();
}

Future<ConversationRepository> _openRepository(
  Directory directory, {
  RepositoryFaultHook? faultHook,
  RepositoryProcessLivenessProbe? processLivenessProbe,
  int maxEntriesPerThread = 100000,
  int maxBytesPerThread = 64 * 1024 * 1024,
}) async {
  final repository = ConversationRepository.forTesting(
    databaseFactory: databaseFactoryFfi,
    databasePath: path.join(
      directory.path,
      ConversationRepository.defaultDatabaseName,
    ),
    contractMapper: const _FixtureContract(),
    faultHook: faultHook,
    processLivenessProbe: processLivenessProbe,
    maxEntriesPerThread: maxEntriesPerThread,
    maxBytesPerThread: maxBytesPerThread,
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

CanonicalItem _item(int ordinal, {String text = 'value'}) => CanonicalItem(
  providerTurnId: 'turn-$ordinal',
  providerItemId: 'item-$ordinal',
  turnOrdinal: ordinal,
  itemOrdinal: 0,
  timelineOrdinal: ordinal,
  kind: 'USER_MESSAGE',
  normalizedPayload: <String, Object?>{'text': text},
  presentationProjection: <String, Object?>{'text': text},
);

ProviderReadEvidence _evidence() => const ProviderReadEvidence(
  method: 'thread/turns/list',
  buildId: 'codex-test-build',
  resultKind: 'full',
  resultDigest: _resultDigest,
  evidenceDigest: _evidenceDigest,
  coverageDigest: _coverageDigest,
);

MaterializationBegin _begin(
  String id, {
  required int revision,
  required int totalItems,
  int pageCount = 1,
  String connectionEpoch = 'connection-1',
  String sourceEpoch = 'source-1',
  String providerEpoch = 'provider-1',
  ReadHealth health = ReadHealth.healthy,
  String? problemCode,
  int? lower,
  int? upper,
  bool isSnapshot = true,
  StructuralCoverage? structural,
  PayloadCoverage? payload,
  ReplicaEmptyProof? emptyProof,
}) => MaterializationBegin(
  materializationId: id,
  key: _key(),
  fence: EnvelopeFence(
    connectionEpoch: connectionEpoch,
    sourceEpoch: sourceEpoch,
    providerInstanceEpoch: providerEpoch,
    runtimeAuthorityGeneration: 1,
  ),
  sourceRevision: revision,
  coverage: Coverage(
    structural:
        structural ??
        (health == ReadHealth.error
            ? StructuralCoverage.partial
            : StructuralCoverage.complete),
    payload: payload ?? PayloadCoverage.complete,
    lowerOrdinal: lower ?? (totalItems == 0 ? null : 1),
    upperOrdinal: upper ?? (totalItems == 0 ? null : totalItems),
  ),
  health: health,
  pageCount: pageCount,
  totalItemCount: totalItems,
  providerReadEvidenceDigest: _evidenceDigest,
  providerReadEvidence: _evidence(),
  problemCode: problemCode,
  isSnapshot: isSnapshot,
  emptyProof: emptyProof,
);

MaterializationPage _page(
  MaterializationBegin begin,
  MaterializationPageBody body, {
  required String digest,
  int index = 0,
  String? previous,
  EnvelopeFence? fence,
}) => MaterializationPage(
  materializationId: begin.materializationId,
  key: begin.key,
  fence: fence ?? begin.fence,
  sourceRevision: begin.sourceRevision,
  pageIndex: index,
  pageCount: begin.pageCount,
  pageDigest: digest,
  previousPageDigest: previous,
  body: body,
);

MaterializationCommit _commit(
  MaterializationBegin begin,
  String pageDigest,
  ConversationRepository repository,
) => MaterializationCommit(
  materializationId: begin.materializationId,
  key: begin.key,
  fence: begin.fence,
  sourceRevision: begin.sourceRevision,
  pageCount: begin.pageCount,
  finalPageDigest: begin.pageCount == 0 ? null : pageDigest,
  pageManifestDigest: repository.materializationPageManifestDigest(
    begin.pageCount == 0 ? const <String>[] : [pageDigest],
  ),
  providerReadEvidenceDigest: begin.providerReadEvidenceDigest,
  emptyProofDigest: begin.emptyProof == null
      ? null
      : repository.replicaEmptyProofDigest(begin.emptyProof!),
);

RuntimeProjectionEnvelope _projection(
  String id, {
  required int revision,
  required String? operation,
  bool complete = false,
  int runtimeGeneration = 1,
  String connectionEpoch = 'connection-1',
  String sourceEpoch = 'source-1',
  String operationText = 'operation',
  int? operationRevision,
}) => RuntimeProjectionEnvelope(
  projectionId: id,
  key: _key(),
  fence: EnvelopeFence(
    connectionEpoch: connectionEpoch,
    sourceEpoch: sourceEpoch,
    providerInstanceEpoch: 'provider-1',
    runtimeAuthorityGeneration: runtimeGeneration,
  ),
  sourceRevision: revision,
  operations: operation == null
      ? const <OperationProjection>[]
      : <OperationProjection>[
          OperationProjection(
            operationId: operation,
            revision: operationRevision ?? revision,
            state: 'queued',
            isTerminal: false,
            value: <String, Object?>{'text': operationText},
          ),
        ],
  operationSnapshotComplete: complete,
);

Matcher _failure(RepositoryFailureCode code) => throwsA(
  isA<ConversationRepositoryException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);
