import 'package:ccpocket/features/session_list/widgets/machine_list.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrapMachineList({
  required bool isRefreshing,
  required VoidCallback onRefresh,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: MachineList(
        machines: const [],
        isRefreshing: isRefreshing,
        onConnect: (_) {},
        onStart: (_) {},
        onEdit: (_) {},
        onDelete: (_) {},
        onAddMachine: () {},
        onRefresh: onRefresh,
      ),
    ),
  );
}

void main() {
  testWidgets('status refresh arrow rotates only while a refresh is active', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      _wrapMachineList(isRefreshing: false, onRefresh: () => refreshCount += 1),
    );

    final buttonFinder = find.byKey(
      const ValueKey('machine_status_refresh_button'),
    );
    final arrowFinder = find.byKey(
      const ValueKey('machine_status_refresh_arrow'),
    );
    expect(buttonFinder, findsOne);
    expect(arrowFinder, findsOne);

    await tester.tap(buttonFinder);
    await tester.pump();
    expect(refreshCount, 1);

    await tester.pumpWidget(
      _wrapMachineList(isRefreshing: true, onRefresh: () => refreshCount += 1),
    );
    final button = tester.widget<IconButton>(buttonFinder);
    expect(button.onPressed, isNull);

    final before = tester.widget<RotationTransition>(arrowFinder).turns.value;
    await tester.pump(const Duration(milliseconds: 200));
    final after = tester.widget<RotationTransition>(arrowFinder).turns.value;
    expect(after, isNot(before));

    await tester.pumpWidget(
      _wrapMachineList(isRefreshing: false, onRefresh: () => refreshCount += 1),
    );
    expect(tester.widget<RotationTransition>(arrowFinder).turns.value, 0);
  });
}
