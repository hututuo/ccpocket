import 'package:ccpocket/features/file_transfer/file_transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FileTransferException keeps its stable code in its display text', () {
    expect(
      const FileTransferException(
        'diagnostic_sensitive_field',
        'Diagnostic report contains a prohibited authentication field',
      ).toString(),
      'diagnostic_sensitive_field: '
      'Diagnostic report contains a prohibited authentication field',
    );
  });

  test('FileTransferException falls back to its code without a message', () {
    expect(
      const FileTransferException('bridge_disconnected').toString(),
      'bridge_disconnected',
    );
  });
}
