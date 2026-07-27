import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccpocket/services/draft_service.dart';

void main() {
  late DraftService draftService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    draftService = DraftService(prefs);
  });

  group('Text draft persistence', () {
    test('saveDraft stores and getDraft retrieves text', () {
      draftService.saveDraft('session-1', 'Hello world');
      expect(draftService.getDraft('session-1'), 'Hello world');
    });

    test('getDraft returns null for unknown session', () {
      expect(draftService.getDraft('unknown'), isNull);
    });

    test('saveDraft with empty text deletes the draft', () {
      draftService.saveDraft('session-1', 'some text');
      expect(draftService.getDraft('session-1'), 'some text');
      draftService.saveDraft('session-1', '');
      expect(draftService.getDraft('session-1'), isNull);
    });

    test('deleteDraft removes the draft', () {
      draftService.saveDraft('session-1', 'draft text');
      draftService.deleteDraft('session-1');
      expect(draftService.getDraft('session-1'), isNull);
    });

    test('migrateDraft moves draft from old to new session ID', () {
      draftService.saveDraft('pending_123', 'migrated text');
      draftService.migrateDraft('pending_123', 'real_456');
      expect(draftService.getDraft('pending_123'), isNull);
      expect(draftService.getDraft('real_456'), 'migrated text');
    });

    test('migrateDraft does nothing when old ID has no draft', () {
      draftService.migrateDraft('nonexistent', 'real_456');
      expect(draftService.getDraft('real_456'), isNull);
    });
  });

  group('Text draft survives reload', () {
    test(
      'draft is available after creating new DraftService from same prefs',
      () async {
        // Save via first instance
        draftService.saveDraft('session-1', 'persistent text');

        // Create second instance with same underlying prefs
        final prefs = await SharedPreferences.getInstance();
        final draftService2 = DraftService(prefs);

        expect(draftService2.getDraft('session-1'), 'persistent text');
      },
    );

    test('migrated draft persists across reload', () async {
      draftService.saveDraft('pending_1', 'will migrate');
      draftService.migrateDraft('pending_1', 'real_1');

      final prefs = await SharedPreferences.getInstance();
      final draftService2 = DraftService(prefs);

      expect(draftService2.getDraft('pending_1'), isNull);
      expect(draftService2.getDraft('real_1'), 'will migrate');
    });
  });

  group('Image draft persistence', () {
    test('saveImageDraft stores and getImageDraft retrieves images', () {
      final images = [
        (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
      ];
      draftService.saveImageDraft('session-1', images);
      final result = draftService.getImageDraft('session-1');
      expect(result, isNotNull);
      expect(result!.length, 1);
      expect(result[0].mimeType, 'image/png');
      expect(result[0].bytes, [1, 2, 3]);
    });

    test('saveImageDraft with empty list deletes the draft', () {
      final images = [
        (bytes: Uint8List.fromList([1]), mimeType: 'image/png'),
      ];
      draftService.saveImageDraft('session-1', images);
      draftService.saveImageDraft('session-1', []);
      expect(draftService.getImageDraft('session-1'), isNull);
    });

    test('migrateImageDraft moves images from old to new session ID', () {
      final images = [
        (bytes: Uint8List.fromList([4, 5]), mimeType: 'image/jpeg'),
      ];
      draftService.saveImageDraft('pending_1', images);
      draftService.migrateImageDraft('pending_1', 'real_1');
      expect(draftService.getImageDraft('pending_1'), isNull);
      final result = draftService.getImageDraft('real_1');
      expect(result, isNotNull);
      expect(result![0].mimeType, 'image/jpeg');
    });

    test(
      'does not decode persisted image drafts during construction',
      () async {
        SharedPreferences.setMockInitialValues({
          'draft_image_v1_session-lazy': '[{"b64":"AQID","mime":"image/png"}]',
        });
        final prefs = await SharedPreferences.getInstance();
        var decodeCalls = 0;
        final service = DraftService(
          prefs,
          imageListDecoder: (value) {
            decodeCalls++;
            expect(value, contains('AQID'));
            return [
              (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
            ];
          },
        );

        expect(decodeCalls, 0);
        expect(service.getImageDraft('session-lazy')?.single.bytes, [1, 2, 3]);
        expect(decodeCalls, 1);
      },
    );

    test('a slow image draft write cannot overwrite a newer draft', () async {
      final first = Completer<String>();
      final second = Completer<String>();
      var encodeCalls = 0;
      final prefs = await SharedPreferences.getInstance();
      final service = DraftService(
        prefs,
        imageListEncoder: (_) {
          encodeCalls++;
          return encodeCalls == 1 ? first.future : second.future;
        },
      );

      service.saveImageDraft('session-race', [
        (bytes: Uint8List.fromList([1]), mimeType: 'image/png'),
      ]);
      service.saveImageDraft('session-race', [
        (bytes: Uint8List.fromList([2]), mimeType: 'image/png'),
      ]);
      expect(encodeCalls, 2);

      second.complete(
        jsonEncode([
          {'b64': 'Ag==', 'mime': 'image/png'},
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      first.complete(
        jsonEncode([
          {'b64': 'AQ==', 'mime': 'image/png'},
        ]),
      );
      await Future<void>.delayed(Duration.zero);

      final restored = DraftService(prefs);
      expect(restored.getImageDraft('session-race')?.single.bytes, [2]);
    });

    test(
      'deleting an image draft fences an unfinished persistence write',
      () async {
        final encoded = Completer<String>();
        final prefs = await SharedPreferences.getInstance();
        final service = DraftService(
          prefs,
          imageListEncoder: (_) => encoded.future,
        );

        service.saveImageDraft('session-delete', [
          (bytes: Uint8List.fromList([1]), mimeType: 'image/png'),
        ]);
        service.deleteImageDraft('session-delete');
        encoded.complete(
          jsonEncode([
            {'b64': 'AQ==', 'mime': 'image/png'},
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        expect(prefs.getString('draft_image_v1_session-delete'), isNull);
        expect(service.getImageDraft('session-delete'), isNull);
      },
    );

    test('migrates a cold persisted image draft without decoding it', () async {
      SharedPreferences.setMockInitialValues({
        'draft_image_v1_pending-cold': '[{"b64":"BAU=","mime":"image/jpeg"}]',
      });
      final prefs = await SharedPreferences.getInstance();
      final service = DraftService(
        prefs,
        imageListDecoder: (_) => throw StateError('must stay lazy'),
      );

      service.migrateImageDraft('pending-cold', 'real-cold');
      await Future<void>.delayed(Duration.zero);

      final restored = DraftService(prefs);
      expect(restored.getImageDraft('pending-cold'), isNull);
      expect(restored.getImageDraft('real-cold')?.single.bytes, [4, 5]);
    });
  });

  group('Pending submission persistence', () {
    PendingChatSubmissionDraft submission(
      String clientMessageId, {
      String text = 'Review @lib/main.dart',
    }) {
      return PendingChatSubmissionDraft(
        clientMessageId: clientMessageId,
        text: text,
        images: [
          (bytes: Uint8List.fromList([7, 8, 9]), mimeType: 'image/png'),
        ],
        mentionablePaths: const ['lib/main.dart'],
        additionalMentions: const [
          {'name': 'report.json', 'path': '/tmp/report.json'},
        ],
      );
    }

    test('survives service recreation with every attachment', () async {
      await draftService.savePendingSubmission(
        'session-1',
        submission('client-1'),
      );

      final prefs = await SharedPreferences.getInstance();
      final restored = DraftService(prefs).getPendingSubmission('session-1');

      expect(restored, isNotNull);
      expect(restored!.clientMessageId, 'client-1');
      expect(restored.text, 'Review @lib/main.dart');
      expect(restored.images.single.bytes, [7, 8, 9]);
      expect(restored.images.single.mimeType, 'image/png');
      expect(restored.mentionablePaths, ['lib/main.dart']);
      expect(restored.additionalMentions, [
        {'name': 'report.json', 'path': '/tmp/report.json'},
      ]);
    });

    test('does not overwrite a different queued submission', () async {
      await draftService.savePendingSubmission(
        'session-1',
        submission('client-1'),
      );

      await expectLater(
        draftService.savePendingSubmission('session-1', submission('client-2')),
        throwsStateError,
      );
      expect(
        draftService.getPendingSubmission('session-1')?.clientMessageId,
        'client-1',
      );
    });

    test('deletes only the matching queued submission', () async {
      await draftService.savePendingSubmission(
        'session-1',
        submission('client-1'),
      );

      expect(
        draftService.deletePendingSubmission(
          'session-1',
          clientMessageId: 'client-2',
        ),
        isFalse,
      );
      expect(draftService.getPendingSubmission('session-1'), isNotNull);
      expect(
        draftService.deletePendingSubmission(
          'session-1',
          clientMessageId: 'client-1',
        ),
        isTrue,
      );
      expect(draftService.getPendingSubmission('session-1'), isNull);
    });

    test(
      'does not decode a persisted submission during construction',
      () async {
        SharedPreferences.setMockInitialValues({
          'draft_pending_submission_v1_session-lazy': jsonEncode({
            'clientMessageId': 'client-lazy',
            'text': 'Lazy submission',
            'images': const [],
            'mentionablePaths': const [],
            'additionalMentions': const [],
          }),
        });
        final prefs = await SharedPreferences.getInstance();
        var decodeCalls = 0;
        final service = DraftService(
          prefs,
          pendingSubmissionDecoder: (value) {
            decodeCalls++;
            expect(value, contains('client-lazy'));
            return PendingChatSubmissionDraft(
              clientMessageId: 'client-lazy',
              text: 'Lazy submission',
            );
          },
        );

        expect(decodeCalls, 0);
        expect(
          service.getPendingSubmission('session-lazy')?.clientMessageId,
          'client-lazy',
        );
        expect(decodeCalls, 1);
      },
    );

    test(
      'a slow same-id submission save cannot overwrite a newer edit',
      () async {
        final first = Completer<String>();
        final second = Completer<String>();
        var encodeCalls = 0;
        final prefs = await SharedPreferences.getInstance();
        final service = DraftService(
          prefs,
          pendingSubmissionEncoder: (_) {
            encodeCalls++;
            return encodeCalls == 1 ? first.future : second.future;
          },
        );

        final firstSave = service.savePendingSubmission(
          'session-race',
          submission('same-client', text: 'First text'),
        );
        final secondSave = service.savePendingSubmission(
          'session-race',
          submission('same-client', text: 'Second text'),
        );
        expect(encodeCalls, 2);

        second.complete(
          jsonEncode({
            'clientMessageId': 'same-client',
            'text': 'Second text',
            'images': const [],
            'mentionablePaths': const [],
            'additionalMentions': const [],
          }),
        );
        first.complete(
          jsonEncode({
            'clientMessageId': 'same-client',
            'text': 'First text',
            'images': const [],
            'mentionablePaths': const [],
            'additionalMentions': const [],
          }),
        );
        await Future.wait([firstSave, secondSave]);

        final restored = DraftService(prefs);
        expect(
          restored.getPendingSubmission('session-race')?.text,
          'Second text',
        );
      },
    );

    test(
      'a superseded encoder failure does not reject the newer edit',
      () async {
        final first = Completer<String>();
        final second = Completer<String>();
        var encodeCalls = 0;
        final prefs = await SharedPreferences.getInstance();
        final service = DraftService(
          prefs,
          pendingSubmissionEncoder: (_) {
            encodeCalls++;
            return encodeCalls == 1 ? first.future : second.future;
          },
        );

        final firstSave = service.savePendingSubmission(
          'session-superseded',
          submission('same-client', text: 'First text'),
        );
        final secondSave = service.savePendingSubmission(
          'session-superseded',
          submission('same-client', text: 'Second text'),
        );
        second.complete(
          jsonEncode({
            'clientMessageId': 'same-client',
            'text': 'Second text',
            'images': const [],
            'mentionablePaths': const [],
            'additionalMentions': const [],
          }),
        );
        first.completeError(StateError('stale encoder failed'));

        await Future.wait([firstSave, secondSave]);
        final restored = DraftService(prefs);
        expect(
          restored.getPendingSubmission('session-superseded')?.text,
          'Second text',
        );
      },
    );

    test(
      'deleting a submission fences an unfinished persistence write',
      () async {
        final encoded = Completer<String>();
        final prefs = await SharedPreferences.getInstance();
        final service = DraftService(
          prefs,
          pendingSubmissionEncoder: (_) => encoded.future,
        );

        final save = service.savePendingSubmission(
          'session-delete',
          submission('client-delete'),
        );
        expect(
          service.deletePendingSubmission(
            'session-delete',
            clientMessageId: 'client-delete',
          ),
          isTrue,
        );
        encoded.complete(
          jsonEncode({
            'clientMessageId': 'client-delete',
            'text': 'Deleted submission',
            'images': const [],
            'mentionablePaths': const [],
            'additionalMentions': const [],
          }),
        );
        await save;

        expect(
          prefs.getString('draft_pending_submission_v1_session-delete'),
          isNull,
        );
        expect(service.getPendingSubmission('session-delete'), isNull);
      },
    );

    test('migrates a cold persisted submission without decoding it', () async {
      SharedPreferences.setMockInitialValues({
        'draft_pending_submission_v1_pending-cold': jsonEncode({
          'clientMessageId': 'client-cold',
          'text': 'Cold submission',
          'images': const [],
          'mentionablePaths': const [],
          'additionalMentions': const [],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final service = DraftService(
        prefs,
        pendingSubmissionDecoder: (_) => throw StateError('must stay lazy'),
      );

      service.migratePendingSubmission('pending-cold', 'real-cold');
      await Future<void>.delayed(Duration.zero);

      final restored = DraftService(prefs);
      expect(restored.getPendingSubmission('pending-cold'), isNull);
      expect(
        restored.getPendingSubmission('real-cold')?.clientMessageId,
        'client-cold',
      );
    });
  });
}
