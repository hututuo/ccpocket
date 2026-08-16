import 'package:ccpocket/features/session_list/widgets/machine_group_card.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/machine.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MachineWithStatus _route(
  String id,
  String host, {
  String name = 'My Mac',
  MachineStatus status = MachineStatus.offline,
  int? latencyMs,
  BridgeVersionInfo? versionInfo,
}) => MachineWithStatus(
  machine: Machine(id: id, name: name, host: host),
  status: status,
  latencyMs: latencyMs,
  versionInfo: versionInfo,
);

Widget _wrap(
  BridgeMachineGroup group, {
  required ValueChanged<MachineWithStatus> onDelete,
  ValueChanged<MachineWithStatus>? onConnect,
  ValueChanged<MachineWithStatus>? onEdit,
  ValueChanged<MachineWithStatus>? onToggleFavorite,
  ValueChanged<MachineWithStatus>? onStop,
  VoidCallback? onRename,
  double textScale = 1,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  theme: AppTheme.lightTheme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: MachineGroupCard(
          group: group,
          onConnect: onConnect ?? (_) {},
          onStart: (_) {},
          onEdit: onEdit ?? (_) {},
          onDelete: onDelete,
          onRename: onRename,
          onToggleFavorite: onToggleFavorite,
          onStop: onStop,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('explains immediate offline and timeout states distinctly', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(
          id: 'offline-group',
          routes: [_route('offline-route', '192.168.1.10')],
        ),
        onDelete: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Mac or Bridge offline'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(
          id: 'timeout-group',
          routes: [
            _route(
              'timeout-route',
              '100.64.0.10',
              status: MachineStatus.unreachable,
            ),
          ],
        ),
        onDelete: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Connection timed out'), findsOneWidget);
  });

  testWidgets('long press deletes a single-route group', (tester) async {
    final route = _route('route-1', '192.168.1.10');
    final deleted = <String>[];
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [route]),
        onDelete: (value) => deleted.add(value.machine.id),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('machine_group_delete_gesture_group-1')),
    );

    expect(deleted, ['route-1']);
  });

  testWidgets('compact connect action does not expand the route list', (
    tester,
  ) async {
    final route = _route(
      'route-1',
      '192.168.1.10',
      status: MachineStatus.online,
    );
    final connected = <String>[];
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [route]),
        onDelete: (_) {},
        onConnect: (value) => connected.add(value.machine.id),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('machine_group_connect_group-1')),
    );
    await tester.pumpAndSettle();

    expect(connected, ['route-1']);
    expect(find.byKey(const ValueKey('machine_route_route-1')), findsNothing);
  });

  testWidgets('multi-route group does not bulk delete on long press', (
    tester,
  ) async {
    final first = _route('route-1', '192.168.1.10');
    final second = _route('route-2', '100.64.0.10');
    final deleted = <String>[];
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [first, second]),
        onDelete: (value) => deleted.add(value.machine.id),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('machine_group_delete_gesture_group-1')),
    );

    expect(deleted, isEmpty);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('machine_route_delete_gesture_route-2')),
    );

    expect(deleted, ['route-2']);
  });

  testWidgets('identity-changed route remains deletable by long press', (
    tester,
  ) async {
    final route = _route(
      'route-1',
      '192.168.1.10',
      status: MachineStatus.identityChanged,
    );
    final deleted = <String>[];
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [route]),
        onDelete: (value) => deleted.add(value.machine.id),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('machine_route_delete_gesture_route-1')),
    );

    expect(deleted, ['route-1']);
  });

  testWidgets('long pressing action buttons never invokes delete', (
    tester,
  ) async {
    final route = _route(
      'route-1',
      '192.168.1.10',
      status: MachineStatus.online,
    );
    final deleted = <String>[];
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [route]),
        onDelete: (value) => deleted.add(value.machine.id),
        onRename: () {},
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('machine_group_connect_group-1')),
    );
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('machine_group_rename_group-1')),
    );
    await tester.longPress(
      find.byKey(const ValueKey('machine_route_connect_route-1')),
    );
    await tester.longPress(
      find.byKey(const ValueKey('machine_route_menu_route-1')),
    );
    await tester.longPress(
      find.byKey(const ValueKey('machine_route_metadata_route-1')),
    );

    expect(deleted, isEmpty);
  });

  testWidgets('route action menu keeps all route commands reachable', (
    tester,
  ) async {
    final route = _route(
      'route-1',
      '192.168.1.10',
      status: MachineStatus.online,
    );
    final actions = <String>[];
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [route]),
        onDelete: (_) => actions.add('delete'),
        onEdit: (_) => actions.add('edit'),
        onToggleFavorite: (_) => actions.add('favorite'),
        onStop: (_) => actions.add('stop'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    final menuFinder = find.byKey(const ValueKey('machine_route_menu_route-1'));
    final dynamic menu = tester.widget(menuFinder);
    final items = List<dynamic>.from(
      menu.itemBuilder(tester.element(menuFinder)) as List,
    );
    final labels = items
        .map((dynamic item) => (item.child as Text).data)
        .toList(growable: false);
    expect(labels, ['Edit', 'Favorite', 'Stop Server', 'Delete']);
    for (final dynamic item in items) {
      final dynamic onSelected = menu.onSelected;
      onSelected(item.value);
    }

    expect(actions, ['edit', 'favorite', 'stop', 'delete']);
  });

  testWidgets('only incompatible routes show a persistent warning icon', (
    tester,
  ) async {
    final oldBridge = _route(
      'old-route',
      '192.168.1.10',
      status: MachineStatus.online,
      versionInfo: const BridgeVersionInfo(
        version: '1.0.0',
        clientBridgeCompatibilityRevision: 0,
      ),
    );
    final matchedBridge = _route(
      'matched-route',
      '100.64.0.10',
      status: MachineStatus.online,
      versionInfo: const BridgeVersionInfo(
        version: '2.0.0',
        clientBridgeCompatibilityRevision: 1,
      ),
    );
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [oldBridge, matchedBridge]),
        onDelete: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    final warning = find.byKey(
      const ValueKey('machine_route_compatibility_warning_old-route'),
    );
    expect(warning, findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('machine_route_compatibility_warning_matched-route'),
      ),
      findsNothing,
    );
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: warning, matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, contains('v1.0.0'));
    expect(tooltip.message, contains('Bridge is older'));
  });

  testWidgets('narrow large-text layout stays compact with inline actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const name = 'MacBook Pro for development and private network access';
    final first = _route(
      'route-1',
      '2001:db8:abcd:1234:5678:90ab:cdef:1234',
      name: name,
      status: MachineStatus.online,
      latencyMs: 42,
    );
    final second = _route(
      'route-2',
      'very-long-tailnet-route-name.example.ts.net',
      name: name,
      latencyMs: 85,
    );
    await tester.pumpWidget(
      _wrap(
        BridgeMachineGroup(id: 'group-1', routes: [first, second]),
        onDelete: (_) {},
        onRename: () {},
        textScale: 1.4,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(name), findsOneWidget);
    expect(tester.takeException(), isNull);
    final card = find.byKey(const ValueKey('machine_group_group-1'));
    expect(tester.getSize(card).height, lessThan(90));
    final groupSummary = tester.widget<Text>(
      find.byKey(const ValueKey('machine_group_route_summary_group-1')),
    );
    expect(groupSummary.maxLines, 1);
    expect(groupSummary.overflow, TextOverflow.fade);
    expect(groupSummary.data, isNot(contains(first.machine.host)));
    expect(groupSummary.data, isNot(contains(second.machine.host)));
    expect(
      find.byKey(const ValueKey('machine_route_address_route-1')),
      findsNothing,
    );

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('machine_group_rename_group-1')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('machine_group_route_summary_group-1')),
          )
          .maxLines,
      1,
    );
    final routeAddress = tester.widget<Text>(
      find.byKey(const ValueKey('machine_route_address_route-1')),
    );
    expect(routeAddress.data, contains(first.machine.host));
    expect(routeAddress.maxLines, 1);
    expect(routeAddress.overflow, TextOverflow.fade);
    final metadata = find.byKey(
      const ValueKey('machine_route_metadata_route-1'),
    );
    final actions = find.byKey(const ValueKey('machine_route_actions_route-1'));
    final routeTile = find.byKey(const ValueKey('machine_route_route-1'));
    expect(tester.getSize(routeTile).height, lessThan(70));
    expect(
      (tester.getCenter(actions).dy - tester.getCenter(metadata).dy).abs(),
      lessThan(18),
    );
    expect(tester.takeException(), isNull);
  });
}
