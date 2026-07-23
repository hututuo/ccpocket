import 'package:ccpocket/models/notification_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationPreferences', () {
    test('keeps critical categories on and progress opt-in by default', () {
      const preferences = NotificationPreferences.defaults;

      expect(preferences.actionRequired, isTrue);
      expect(preferences.taskCompleted, isTrue);
      expect(preferences.taskFailed, isTrue);
      expect(preferences.progress, isFalse);
      expect(
        preferences.enabledRemoteEventTypes,
        isNot(contains(NotificationPreferences.sessionProgressEvent)),
      );
    });

    test('decodes missing future fields with compatibility defaults', () {
      final preferences = NotificationPreferences.fromJson({
        'taskCompleted': false,
      });

      expect(preferences.actionRequired, isTrue);
      expect(preferences.taskCompleted, isFalse);
      expect(preferences.taskFailed, isTrue);
      expect(preferences.progress, isFalse);
      expect(preferences.showWhileAppOpen, isTrue);
    });

    test('maps every known remote event to its category', () {
      const preferences = NotificationPreferences(
        actionRequired: false,
        taskCompleted: true,
        taskFailed: false,
        progress: true,
      );

      expect(
        preferences.allowsRemoteEvent(
          NotificationPreferences.approvalRequiredEvent,
        ),
        isFalse,
      );
      expect(
        preferences.allowsRemoteEvent(
          NotificationPreferences.sessionCompletedEvent,
        ),
        isTrue,
      );
      expect(
        preferences.allowsRemoteEvent(
          NotificationPreferences.sessionFailedEvent,
        ),
        isFalse,
      );
      expect(
        preferences.allowsRemoteEvent(
          NotificationPreferences.sessionProgressEvent,
        ),
        isTrue,
      );
      expect(preferences.allowsRemoteEvent('file_received'), isTrue);
    });
  });
}
