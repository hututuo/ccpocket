import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file peek and source artifacts prefer the active worktree root', () {
    expect(
      resolveChatFileRoot(
        worktreePath: '/repo/.worktrees/feature',
        projectPath: '/repo',
      ),
      '/repo/.worktrees/feature',
    );
    expect(
      resolveChatFileRoot(worktreePath: '  ', projectPath: '/repo'),
      '/repo',
    );
    expect(resolveChatFileRoot(), isNull);
  });
}
