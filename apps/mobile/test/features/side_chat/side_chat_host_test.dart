import 'package:ccpocket/features/local_session_features/host/local_session_feature.dart';
import 'package:ccpocket/features/local_session_features/host/local_session_feature_host.dart';
import 'package:ccpocket/features/side_chat/state/ephemeral_side_chat_registry_service.dart';
import 'package:ccpocket/features/side_chat/state/side_chat_controller.dart';
import 'package:ccpocket/features/side_chat/widgets/ephemeral_side_chat_pane.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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
    required this.registryService,
    required this.openedPanes,
  });

  final CodexSessionFeatureContext context;
  final _Bridge bridge;
  final DraftService draftService;
  final EphemeralSideChatRegistryService registryService;
  final List<_OpenedPane> openedPanes;
}

Future<_HostHarness> _pumpHost(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'draft_v1_parent-1': 'main-session draft',
  });
  final draftService = DraftService(await SharedPreferences.getInstance());
  final bridge = _Bridge();
  final registryService = EphemeralSideChatRegistryService(
    bridge: BridgeServiceEphemeralSideChatGateway(bridge),
  );
  final inputController = TextEditingController(text: 'main composer');
  final openedPanes = <_OpenedPane>[];
  late CodexSessionFeatureContext featureContext;

  await tester.pumpWidget(
    ChangeNotifierProvider<EphemeralSideChatRegistryService>.value(
      value: registryService,
      child: RepositoryProvider<DraftService>.value(
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
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );

  addTearDown(inputController.dispose);
  addTearDown(registryService.dispose);
  addTearDown(bridge.dispose);
  return _HostHarness(
    context: featureContext,
    bridge: bridge,
    draftService: draftService,
    registryService: registryService,
    openedPanes: openedPanes,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('host exposes the direct side-chat menu entry', (tester) async {
    final harness = await _pumpHost(tester);

    final action = LocalSessionFeatureHost.overflowActions(
      harness.context,
    ).singleWhere((candidate) => candidate.featureId == 'side_chat');
    expect(action.label, 'Side chat');
    expect(action.icon, Icons.chat_bubble_outline);
    expect(action.order, 30);

    final menuItem =
        LocalSessionFeatureHost.overflowMenuItems(harness.context).singleWhere(
              (entry) =>
                  entry.key == const ValueKey('menu_local_feature_side_chat'),
            )
            as PopupMenuItem<String>;
    expect(menuItem.value, 'local_feature:side_chat');
    expect(
      LocalSessionFeatureHost.featureIdFromMenuValue(menuItem.value!),
      'side_chat',
    );
    expect(harness.bridge.sent, isEmpty);
  });

  testWidgets('selected text only opens a prefilled pane without sending', (
    tester,
  ) async {
    final harness = await _pumpHost(tester);

    final selectionAction = LocalSessionFeatureHost.selectionActions(
      harness.context,
    ).singleWhere((candidate) => candidate.id == 'side_chat');
    expect(selectionAction.label, 'Open in side chat');

    selectionAction.onSelected('bounded selected text');
    await tester.pump();

    expect(harness.openedPanes, hasLength(1));
    final opened = harness.openedPanes.single;
    expect(opened.featureId, 'side_chat');
    expect(opened.arguments['initialSelection'], 'bounded selected text');
    expect(opened.arguments['selectionRevision'], isA<int>());
    expect(opened.arguments['selectionRevision'] as int, greaterThan(0));
    expect(harness.bridge.sent, isEmpty);
    expect(harness.draftService.getDraft('parent-1'), 'main-session draft');
    expect(
      harness.draftService.getDraft(SideChatController.draftKeyFor('parent-1')),
      isNull,
    );
  });

  testWidgets('host exposes the expected side-chat pane descriptor', (
    tester,
  ) async {
    final harness = await _pumpHost(tester);
    final descriptor = LocalSessionFeatureHost.paneDescriptor('side_chat');

    expect(descriptor, isNotNull);
    expect(descriptor!.featureId, 'side_chat');
    expect(descriptor.title(harness.context.context), 'Side chat');
    expect(descriptor.sheetHeightFactor, 0.92);
    expect(descriptor.rememberPerSession, isFalse);

    var closed = false;
    void onClose() => closed = true;
    final pane = descriptor.builder(
      WorkspaceFeaturePaneContext(
        context: harness.context.context,
        sessionId: 'parent-1',
        bridge: harness.bridge,
        arguments: const {
          'initialSelection': 'prefill from host',
          'selectionRevision': 42,
        },
        onClose: onClose,
      ),
    );

    expect(pane, isA<EphemeralSideChatPane>());
    final panel = pane as EphemeralSideChatPane;
    expect(panel.parentSessionId, 'parent-1');
    expect(panel.bridgeService, same(harness.bridge));
    expect(panel.registryService, same(harness.registryService));
    expect(panel.draftService, same(harness.draftService));
    expect(panel.initialSelection, 'prefill from host');
    expect(panel.selectionRevision, 42);
    expect(panel.onClose, same(onClose));
    panel.onClose!();
    expect(closed, isTrue);
    expect(harness.bridge.sent, isEmpty);
  });
}
