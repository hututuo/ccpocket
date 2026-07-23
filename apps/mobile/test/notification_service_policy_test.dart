import 'package:ccpocket/models/notification_preferences.dart';
import 'package:ccpocket/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NotificationService.instance.configure(NotificationPreferences.defaults);
  });

  test(
    'applies category and foreground policy before showing remote alerts',
    () {
      NotificationService.instance.configure(
        const NotificationPreferences(
          taskCompleted: true,
          progress: false,
          showWhileAppOpen: false,
        ),
      );

      expect(
        NotificationService.instance.allowsRemoteEvent(
          NotificationPreferences.sessionProgressEvent,
          appIsForeground: false,
        ),
        isFalse,
      );
      expect(
        NotificationService.instance.allowsRemoteEvent(
          NotificationPreferences.sessionCompletedEvent,
          appIsForeground: true,
        ),
        isFalse,
      );
      expect(
        NotificationService.instance.allowsRemoteEvent(
          NotificationPreferences.sessionCompletedEvent,
          appIsForeground: false,
        ),
        isTrue,
      );
    },
  );
}
