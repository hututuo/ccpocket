import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/assistant_bubble.dart';
import 'package:ccpocket/widgets/chat_selection_actions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, TargetPlatform platform) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.darkTheme.copyWith(platform: platform),
    home: Scaffold(body: child),
  );
}

Future<List<ContextMenuButtonItem>> _editableMenu(
  WidgetTester tester,
  Key key, {
  int start = 0,
  int? end,
}) async {
  final selectableFinder = find.byKey(key);
  final editableFinder = find.descendant(
    of: selectableFinder,
    matching: find.byType(EditableText),
  );
  final editable = tester.widget<EditableText>(editableFinder);
  editable.controller.selection = TextSelection(
    baseOffset: start,
    extentOffset: end ?? editable.controller.text.length,
  );
  await tester.pump();

  final selectable = tester.widget<SelectableText>(selectableFinder);
  final state = tester.state<EditableTextState>(editableFinder);
  final toolbar =
      selectable.contextMenuBuilder!(state.context, state)
          as AdaptiveTextSelectionToolbar;
  return toolbar.buttonItems!;
}

Future<List<ContextMenuButtonItem>> _selectionAreaMenu(
  WidgetTester tester,
) async {
  final areaFinder = find.byType(SelectionArea);
  final area = tester.widget<SelectionArea>(areaFinder);
  final areaState = tester.state<SelectionAreaState>(areaFinder);
  areaState.selectableRegion.selectAll();
  await tester.pump();
  final toolbar =
      area.contextMenuBuilder!(areaState.context, areaState.selectableRegion)
          as AdaptiveTextSelectionToolbar;
  return toolbar.buttonItems!;
}

ContextMenuButtonItem _item(List<ContextMenuButtonItem> items, String label) =>
    items.singleWhere((item) => item.label == label);

List<ContextMenuButtonItem> _defaultEditableItems(
  WidgetTester tester,
  Key key,
) {
  final editableFinder = find.descendant(
    of: find.byKey(key),
    matching: find.byType(EditableText),
  );
  return tester.state<EditableTextState>(editableFinder).contextMenuButtonItems;
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('keeps defaults and composes feature actions on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final first = <String>[];
      final second = <String>[];
      await tester.pumpWidget(
        _wrap(
          ChatSelectionActionsScope(
            actions: [
              ChatSelectionAction(
                id: 'first',
                label: 'First action',
                onSelected: first.add,
              ),
              ChatSelectionAction(
                id: 'second',
                label: 'Second action',
                onSelected: second.add,
              ),
            ],
            child: const SelectableText(
              'hello world',
              key: ValueKey('selectable'),
              contextMenuBuilder: chatSelectableTextContextMenuBuilder,
            ),
          ),
          platform,
        ),
      );

      final items = await _editableMenu(
        tester,
        const ValueKey('selectable'),
        end: 5,
      );
      final defaultItems = _defaultEditableItems(
        tester,
        const ValueKey('selectable'),
      );
      debugDefaultTargetPlatformOverride = null;
      for (final defaultItem in defaultItems) {
        expect(
          items.any(
            (item) =>
                item.type == defaultItem.type &&
                item.label == defaultItem.label,
          ),
          true,
        );
      }
      _item(items, 'First action').onPressed!();
      _item(items, 'Second action').onPressed!();
      expect(first, ['hello']);
      expect(second, ['hello']);
    });
  }

  testWidgets('real Markdown uses one outer selection system on iOS', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final selected = <String>[];
    final message = AssistantServerMessage(
      message: AssistantMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: const [TextContent(text: '**selected** Markdown')],
        model: 'codex',
      ),
    );
    await tester.pumpWidget(
      _wrap(
        ChatSelectionActionsScope(
          actions: [
            ChatSelectionAction(
              id: 'inspect',
              label: 'Inspect',
              onSelected: selected.add,
            ),
          ],
          child: AssistantBubble(message: message),
        ),
        TargetPlatform.iOS,
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    final items = await _selectionAreaMenu(tester);
    debugDefaultTargetPlatformOverride = null;
    _item(items, 'Inspect').onPressed!();
    expect(selected.single, contains('selected'));
    expect(selected.single, contains('Markdown'));
  });

  testWidgets('explicit actions stay local and override scope', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final explicit = <String>[];
    final inherited = <String>[];
    await tester.pumpWidget(
      _wrap(
        ChatSelectionActionsScope(
          actions: [
            ChatSelectionAction(
              id: 'inherited',
              label: 'Inherited',
              onSelected: inherited.add,
            ),
          ],
          child: SelectableText(
            'explicit callback',
            key: const ValueKey('selectable'),
            contextMenuBuilder: createChatSelectableTextContextMenuBuilder(
              actions: [
                ChatSelectionAction(
                  id: 'explicit',
                  label: 'Explicit',
                  onSelected: explicit.add,
                ),
              ],
            ),
          ),
        ),
        TargetPlatform.android,
      ),
    );

    final items = await _editableMenu(
      tester,
      const ValueKey('selectable'),
      end: 8,
    );
    debugDefaultTargetPlatformOverride = null;
    _item(items, 'Explicit').onPressed!();
    expect(items.any((item) => item.label == 'Inherited'), false);
    expect(explicit, ['explicit']);
    expect(inherited, isEmpty);
  });

  testWidgets('chat cap preserves a complete grapheme cluster', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final selected = <String>[];
    const family = '👨‍👩‍👧‍👦';
    final text = '${List.filled(11999, 'x').join()}${family}z';
    await tester.pumpWidget(
      _wrap(
        SelectableText(
          text,
          key: const ValueKey('selectable'),
          contextMenuBuilder: createChatSelectableTextContextMenuBuilder(
            actions: [
              ChatSelectionAction(
                id: 'bounded',
                label: 'Bounded',
                onSelected: selected.add,
              ),
            ],
          ),
        ),
        TargetPlatform.android,
      ),
    );

    final items = await _editableMenu(tester, const ValueKey('selectable'));
    debugDefaultTargetPlatformOverride = null;
    _item(items, 'Bounded').onPressed!();
    expect(selected.single, endsWith(family));
    expect(selected.single, isNot(endsWith('z')));
  });

  testWidgets('unsupported platforms keep the original menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(
      _wrap(
        ChatSelectionActionsScope(
          actions: [
            ChatSelectionAction(
              id: 'hidden',
              label: 'Hidden action',
              onSelected: (_) {},
            ),
          ],
          child: const SelectableText(
            'hello',
            key: ValueKey('selectable'),
            contextMenuBuilder: chatSelectableTextContextMenuBuilder,
          ),
        ),
        TargetPlatform.linux,
      ),
    );
    final items = await _editableMenu(tester, const ValueKey('selectable'));
    debugDefaultTargetPlatformOverride = null;
    expect(items.any((item) => item.label == 'Hidden action'), false);
  });
}
