import 'package:ccpocket/features/local_session_features/host/local_session_feature.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature_host.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends BridgeService {
  final sent = <ClientMessage>[];

  @override
  bool get isConnected => true;

  @override
  void send(ClientMessage message) => sent.add(message);
}

typedef _OpenedPane = ({String featureId, Map<String, Object?> arguments});

class _HostHarness {
  const _HostHarness({
    required this.context,
    required this.bridge,
    required this.draftService,
    required this.openedPanes,
    required this.forkedDrafts,
  });

  final CodexSessionFeatureContext context;
  final _Bridge bridge;
  final DraftService draftService;
  final List<_OpenedPane> openedPanes;
  final List<String?> forkedDrafts;
}

Future<_HostHarness> _pumpHost(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'draft_v1_parent-1': 'main-session draft',
  });
  final draftService = DraftService(await SharedPreferences.getInstance());
  final bridge = _Bridge();
  final inputController = TextEditingController(text: 'main composer');
  final openedPanes = <_OpenedPane>[];
  final forkedDrafts = <String?>[];
  late CodexSessionFeatureContext featureContext;

  await tester.pumpWidget(
    RepositoryProvider<DraftService>.value(
      value: draftService,
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            featureContext = CodexSessionFeatureContext(
              context: context,
              sessionId: 'parent-1',
              bridge: bridge,
              inputController: inputController,
              draftService: draftService,
              openPane: (featureId, {arguments = const {}}) async {
                openedPanes.add((
                  featureId: featureId,
                  arguments: Map.unmodifiable(arguments),
                ));
              },
              forkConversation: ({initialDraft}) async {
                forkedDrafts.add(initialDraft);
              },
            );
            return const SizedBox();
          },
        ),
      ),
    ),
  );

  addTearDown(inputController.dispose);
  addTearDown(bridge.dispose);
  return _HostHarness(
    context: featureContext,
    bridge: bridge,
    draftService: draftService,
    openedPanes: openedPanes,
    forkedDrafts: forkedDrafts,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('host exposes the durable side-chat pane independently', (
    tester,
  ) async {
    final harness = await _pumpHost(tester);

    expect(
      LocalSessionFeatureHost.overflowActions(
        harness.context,
      ).where((candidate) => candidate.featureId == 'side_chat'),
      hasLength(1),
    );
    expect(LocalSessionFeatureHost.paneDescriptor('side_chat'), isNotNull);
    expect(harness.bridge.sent, isEmpty);
  });

  testWidgets('selected text opens side chat without invoking ordinary fork', (
    tester,
  ) async {
    final harness = await _pumpHost(tester);

    final selectionAction = LocalSessionFeatureHost.selectionActions(
      harness.context,
    ).singleWhere((candidate) => candidate.id == 'side_chat');
    expect(selectionAction.label, 'Open side chat with selected text');

    selectionAction.onSelected('bounded selected text');
    await tester.pump();

    expect(harness.openedPanes, hasLength(1));
    expect(harness.openedPanes.single.featureId, 'side_chat');
    expect(
      harness.openedPanes.single.arguments['initialSelection'],
      'bounded selected text',
    );
    expect(harness.forkedDrafts, isEmpty);
    expect(harness.bridge.sent, isEmpty);
    expect(harness.draftService.getDraft('parent-1'), 'main-session draft');
  });
}
