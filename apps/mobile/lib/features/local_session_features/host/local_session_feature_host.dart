import 'package:flutter/material.dart';

import '../../../widgets/chat_selection_actions.dart';
import '../slots/add_to_conversation_ui_slot.dart';
import '../slots/session_insights_ui_slot.dart';
import '../slots/side_chat_ui_slot.dart';
import '../slots/subagents_ui_slot.dart';
import 'local_session_feature.dart';

class LocalSessionFeatureHost {
  static const menuValuePrefix = 'local_feature:';

  static final List<LocalSessionFeatureSlot> _slots = [
    sessionInsightsUiSlot,
    subagentsUiSlot,
    addToConversationUiSlot,
    sideChatUiSlot,
  ];

  static List<SessionMenuAction> overflowActions(
    CodexSessionFeatureContext context,
  ) {
    final byId = <String, SessionMenuAction>{};
    for (final slot in _slots) {
      for (final action in slot.overflowActions(context)) {
        if (action.featureId != slot.featureId) {
          throw StateError(
            'Feature ${slot.featureId} contributed action ${action.featureId}',
          );
        }
        if (byId.containsKey(action.featureId)) {
          throw StateError(
            'Duplicate local feature action: ${action.featureId}',
          );
        }
        byId[action.featureId] = action;
      }
    }
    final result = byId.values.toList()
      ..sort((a, b) {
        final order = a.order.compareTo(b.order);
        return order != 0 ? order : a.featureId.compareTo(b.featureId);
      });
    return List.unmodifiable(result);
  }

  static List<PopupMenuEntry<String>> overflowMenuItems(
    CodexSessionFeatureContext context,
  ) {
    return overflowActions(context)
        .map(
          (action) => PopupMenuItem<String>(
            key: ValueKey('menu_local_feature_${action.featureId}'),
            value: '$menuValuePrefix${action.featureId}',
            child: ListTile(
              leading: Icon(action.icon, size: 20),
              title: Text(action.label),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        )
        .toList(growable: false);
  }

  static String? featureIdFromMenuValue(String value) {
    if (!value.startsWith(menuValuePrefix)) return null;
    final featureId = value.substring(menuValuePrefix.length);
    return featureId.isEmpty ? null : featureId;
  }

  static List<Widget> statusWidgets(CodexSessionFeatureContext context) {
    return List.unmodifiable(
      _slots.expand((slot) => slot.statusWidgets(context)),
    );
  }

  static List<ChatSelectionAction> selectionActions(
    CodexSessionFeatureContext context,
  ) {
    final byId = <Object, ChatSelectionAction>{};
    for (final slot in _slots) {
      for (final action in slot.selectionActions(context)) {
        if (byId.containsKey(action.id)) {
          throw StateError('Duplicate chat selection action: ${action.id}');
        }
        byId[action.id] = action;
      }
    }
    return List.unmodifiable(byId.values);
  }

  static WorkspaceFeaturePaneDescriptor? paneDescriptor(String featureId) {
    for (final slot in _slots) {
      if (slot.featureId == featureId) return slot.paneDescriptor;
    }
    return null;
  }
}
