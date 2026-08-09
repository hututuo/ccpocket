import 'package:ccpocket/features/session_list/widgets/machine_group_card.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/machine.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MachineWithStatus _route(
  String id,
  String host, {
  MachineStatus status = MachineStatus.offline,
}) => MachineWithStatus(
  machine: Machine(id: id, name: 'My Mac', host: host),
  status: status,
);

Widget _wrap(
  BridgeMachineGroup group, {
  required ValueChanged<MachineWithStatus> onDelete,
  ValueChanged<MachineWithStatus>? onConnect,
  VoidCallback? onRename,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  theme: AppTheme.lightTheme,
  home: Scaffold(
    body: MachineGroupCard(
      group: group,
      onConnect: onConnect ?? (_) {},
      onStart: (_) {},
      onEdit: (_) {},
      onDelete: onDelete,
      onRename: onRename,
    ),
  ),
);

void main() {
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

    expect(deleted, isEmpty);
  });
}
