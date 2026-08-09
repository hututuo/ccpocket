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
}) => MachineWithStatus(
  machine: Machine(id: id, name: name, host: host),
  status: status,
  latencyMs: latencyMs,
);

Widget _wrap(
  BridgeMachineGroup group, {
  required ValueChanged<MachineWithStatus> onDelete,
  ValueChanged<MachineWithStatus>? onConnect,
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
          onEdit: (_) {},
          onDelete: onDelete,
          onRename: onRename,
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
    expect(find.text('Mac or Bridge offline'), findsOneWidget);

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
    expect(find.text('Connection timed out'), findsOneWidget);
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
      find.byKey(const ValueKey('machine_group_rename_group-1')),
    );
    await tester.longPress(
      find.byKey(const ValueKey('machine_group_connect_group-1')),
    );
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
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

  testWidgets('narrow large-text layout wraps instead of using ellipsis', (
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
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('machine_group_group-1'));
    final textWidgets = tester.widgetList<Text>(
      find.descendant(of: card, matching: find.byType(Text)),
    );
    expect(
      textWidgets.where((text) => text.overflow == TextOverflow.ellipsis),
      isEmpty,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('machine_group_route_summary_group-1')),
          )
          .maxLines,
      isNull,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('machine_route_address_route-1')),
          )
          .maxLines,
      isNull,
    );
    final metadata = find.byKey(
      const ValueKey('machine_route_metadata_route-1'),
    );
    final actions = find.byKey(const ValueKey('machine_route_actions_route-1'));
    expect(
      tester.getTopLeft(actions).dy,
      greaterThan(tester.getBottomLeft(metadata).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
