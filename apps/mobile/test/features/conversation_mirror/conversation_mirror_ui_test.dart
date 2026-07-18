import 'package:ccpocket/features/conversation_mirror/conversation_mirror_badge.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_service.dart';
import 'package:ccpocket/features/conversation_mirror/conversation_mirror_session_actions.dart';
import 'package:ccpocket/features/conversation_mirror/storage/conversation_mirror_storage.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/widgets/adaptive_context_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart' hide Provider;

class _FakeConversationMirrorService extends ConversationMirrorService {
  _FakeConversationMirrorService({
    required this.unsupported,
    required this.localCopy,
    this.downloadResult,
  }) : super(
         bridge: BridgeService(),
         store: ConversationMirrorStore(ConversationMirrorDatabase()),
         database: ConversationMirrorDatabase(),
       );

  final bool unsupported;
  final bool localCopy;
  final ConversationMirrorSyncResult? downloadResult;

  @override
  bool get isAvailable => true;

  @override
  bool get featureUnsupported => unsupported;

  @override
  bool hasLocalCopy(RecentSession session) => localCopy;

  @override
  bool isSyncing(RecentSession session) => false;

  @override
  Future<ConversationMirrorSyncResult> downloadAndWatch(
    RecentSession session,
  ) async =>
      downloadResult ??
      const ConversationMirrorSyncResult(success: true, changed: false);
}

const _session = RecentSession(
  sessionId: 'thread-1',
  provider: 'codex',
  firstPrompt: 'hello',
  created: '2026-07-18T00:00:00Z',
  modified: '2026-07-18T00:00:00Z',
  gitBranch: 'main',
  projectPath: '/tmp/project',
  isSidechain: false,
);

Widget _wrap(ConversationMirrorService service, Widget child) =>
    ChangeNotifierProvider<ConversationMirrorService>.value(
      value: service,
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('old Bridge hides download when there is no local copy', (
    tester,
  ) async {
    final service = _FakeConversationMirrorService(
      unsupported: true,
      localCopy: false,
    );

    await tester.pumpWidget(
      _wrap(service, const ConversationMirrorBadge(session: _session)),
    );

    expect(
      find.byKey(const ValueKey('conversation_mirror_download_badge')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation_mirror_saved_badge')),
      findsNothing,
    );
  });

  testWidgets('old Bridge keeps a removable local copy visible', (
    tester,
  ) async {
    final service = _FakeConversationMirrorService(
      unsupported: true,
      localCopy: true,
    );
    late List<AdaptiveActionMenuItem<String>> actions;

    await tester.pumpWidget(
      _wrap(
        service,
        Column(
          children: [
            const ConversationMirrorBadge(session: _session),
            Builder(
              builder: (context) {
                actions = conversationMirrorActionItems(context, _session);
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
    );

    final savedButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('conversation_mirror_saved_badge')),
    );
    expect(savedButton.onPressed, isNull);
    expect(actions.map((action) => action.value), [
      conversationMirrorRemoveAction,
    ]);
  });

  testWidgets('pre-feature Bridge timeout uses the friendly fallback message', (
    tester,
  ) async {
    final service = _FakeConversationMirrorService(
      unsupported: false,
      localCopy: false,
      downloadResult: const ConversationMirrorSyncResult(
        success: false,
        changed: false,
        errorCode: 'capability_not_negotiated',
        error: 'technical handshake detail',
      ),
    );

    await tester.pumpWidget(
      _wrap(
        service,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => handleConversationMirrorAction(
              context,
              _session,
              conversationMirrorDownloadAction,
            ),
            child: const Text('download'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('download'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This Bridge does not support conversation mirrors; existing loading remains active',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('technical handshake detail'), findsNothing);
  });
}
