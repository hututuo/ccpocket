import 'package:flutter_test/flutter_test.dart';
import 'package:ccpocket/services/bridge_service.dart';

void main() {
  group('bridgePrivateHttpHeaders', () {
    test('forwards the decoded WebSocket API key as a bearer credential', () {
      expect(
        bridgePrivateHttpHeaders(
          'wss://mac.example:8765/ws?token=owner%2Bkey%2F1',
        ),
        {'Authorization': 'Bearer owner+key/1'},
      );
    });

    test('keeps private HTTP requests credential-free without a key', () {
      expect(bridgePrivateHttpHeaders('ws://100.64.0.2:8765'), isEmpty);
      expect(bridgePrivateHttpHeaders(null), isEmpty);
      expect(bridgePrivateHttpHeaders('not a URL'), isEmpty);
    });
  });
}
