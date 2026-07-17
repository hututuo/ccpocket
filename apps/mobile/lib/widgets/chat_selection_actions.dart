import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'google_search_text_selection.dart';

typedef SelectedTextContextAction = void Function(String selectedText);

/// Maximum number of user-perceived characters forwarded by a selection menu.
const int selectionContextActionMaxCharacters = 12000;

/// One optional action contributed by a removable chat feature.
///
/// The selection infrastructure owns only menu composition and text bounds.
/// Labels and behavior stay in the feature that contributes the action.
class ChatSelectionAction {
  final Object id;
  final String label;
  final SelectedTextContextAction onSelected;

  const ChatSelectionAction({
    required this.id,
    required this.label,
    required this.onSelected,
  });
}

bool get _supportsChatSelectionActions =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Session-local action contributions for selectable transcript content.
class ChatSelectionActionsScope extends InheritedWidget {
  final List<ChatSelectionAction> actions;

  const ChatSelectionActionsScope({
    super.key,
    this.actions = const [],
    required super.child,
  });

  static ChatSelectionActionsScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ChatSelectionActionsScope>();
  }

  @override
  bool updateShouldNotify(ChatSelectionActionsScope oldWidget) {
    return !listEquals(actions, oldWidget.actions);
  }
}

/// Whether Markdown must delegate selection to an outer [ChatSelectionArea].
bool chatSelectionAreaMenuEnabled(BuildContext context) {
  final scope = ChatSelectionActionsScope.maybeOf(context);
  return googleSearchSelectionMenuEnabled ||
      (_supportsChatSelectionActions && (scope?.actions.isNotEmpty ?? false));
}

EditableTextContextMenuBuilder createChatSelectableTextContextMenuBuilder({
  List<ChatSelectionAction>? actions,
}) {
  return (context, editableTextState) => _buildEditableMenu(
    context: context,
    editableTextState: editableTextState,
    actions: actions,
  );
}

Widget chatSelectableTextContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return _buildEditableMenu(
    context: context,
    editableTextState: editableTextState,
  );
}

Widget _buildEditableMenu({
  required BuildContext context,
  required EditableTextState editableTextState,
  List<ChatSelectionAction>? actions,
}) {
  final resolvedActions = _resolveActions(context, actions);
  if (!googleSearchSelectionMenuEnabled && resolvedActions.isEmpty) {
    return AdaptiveTextSelectionToolbar.editableText(
      editableTextState: editableTextState,
    );
  }

  final selection = editableTextState.textEditingValue.selection.textInside(
    editableTextState.textEditingValue.text,
  );
  var items = _withChatSelectionItems(
    items: editableTextState.contextMenuButtonItems,
    selectedText: selection,
    hideToolbar: editableTextState.hideToolbar,
    actions: resolvedActions,
  );
  items = withGoogleSearchSelectionItem(
    context: context,
    items: items,
    selectedText: selection,
    hideToolbar: editableTextState.hideToolbar,
  );
  return AdaptiveTextSelectionToolbar.buttonItems(
    buttonItems: items,
    anchors: editableTextState.contextMenuAnchors,
  );
}

class ChatSelectionArea extends StatefulWidget {
  final Widget child;
  final List<ChatSelectionAction>? actions;

  const ChatSelectionArea({super.key, required this.child, this.actions});

  @override
  State<ChatSelectionArea> createState() => _ChatSelectionAreaState();
}

class _ChatSelectionAreaState extends State<ChatSelectionArea> {
  String _selectedText = '';

  @override
  Widget build(BuildContext context) {
    final actions = _resolveActions(context, widget.actions);
    if (!googleSearchSelectionMenuEnabled && actions.isEmpty) {
      return widget.child;
    }

    return SelectionArea(
      onSelectionChanged: (content) {
        _selectedText = content?.plainText ?? '';
      },
      contextMenuBuilder: (context, selectableRegionState) {
        var items = _withChatSelectionItems(
          items: selectableRegionState.contextMenuButtonItems,
          selectedText: _selectedText,
          hideToolbar: selectableRegionState.hideToolbar,
          actions: actions,
        );
        items = withGoogleSearchSelectionItem(
          context: context,
          items: items,
          selectedText: _selectedText,
          hideToolbar: selectableRegionState.hideToolbar,
        );
        return AdaptiveTextSelectionToolbar.buttonItems(
          buttonItems: items,
          anchors: selectableRegionState.contextMenuAnchors,
        );
      },
      child: widget.child,
    );
  }
}

List<ChatSelectionAction> _resolveActions(
  BuildContext context,
  List<ChatSelectionAction>? explicitActions,
) {
  return explicitActions ??
      ChatSelectionActionsScope.maybeOf(context)?.actions ??
      const [];
}

List<ContextMenuButtonItem> _withChatSelectionItems({
  required List<ContextMenuButtonItem> items,
  required String selectedText,
  required VoidCallback hideToolbar,
  required List<ChatSelectionAction> actions,
}) {
  final result = List<ContextMenuButtonItem>.of(items);
  if (!_supportsChatSelectionActions || actions.isEmpty) return result;
  final normalized = normalizeChatSelection(selectedText);
  if (normalized.isEmpty) return result;

  final actionItems = actions
      .map(
        (action) => ContextMenuButtonItem(
          label: action.label,
          onPressed: () {
            hideToolbar();
            action.onSelected(normalized);
          },
        ),
      )
      .toList(growable: false);
  final insertIndex = result.indexWhere(
    (item) => item.type == ContextMenuButtonType.selectAll,
  );
  if (insertIndex < 0) {
    result.addAll(actionItems);
  } else {
    result.insertAll(insertIndex, actionItems);
  }
  return result;
}

String normalizeChatSelection(String selectedText) {
  final trimmed = selectedText.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.characters
      .take(selectionContextActionMaxCharacters)
      .toString();
}
