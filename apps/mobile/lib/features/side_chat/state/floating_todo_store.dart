import 'dart:convert';
import 'dart:typed_data';

import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int floatingTodoMaxItems = 200;
const int floatingTodoMaxTextCharacters = 4000;

/// A small, rebuildable item owned by one durable main conversation.
///
/// This is intentionally separate from the provider transcript. A todo is a
/// local convenience and its `submitted` bit only means that the existing
/// ChatSessionCubit accepted the send request; it is not a provider/model ACK.
class FloatingTodoItem {
  const FloatingTodoItem({
    required this.id,
    required this.text,
    this.completed = false,
    this.submitted = false,
  });

  final String id;
  final String text;
  final bool completed;
  final bool submitted;

  FloatingTodoItem copyWith({String? text, bool? completed, bool? submitted}) =>
      FloatingTodoItem(
        id: id,
        text: text ?? this.text,
        completed: completed ?? this.completed,
        submitted: submitted ?? this.submitted,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'completed': completed,
    'submitted': submitted,
  };

  static FloatingTodoItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final text = value['text'];
    if (id is! String || text is! String) return null;
    final normalizedId = id.trim();
    final normalizedText = text.trim();
    if (normalizedId.isEmpty || normalizedText.isEmpty) return null;
    if (normalizedId.length > 256 ||
        normalizedText.length > floatingTodoMaxTextCharacters) {
      return null;
    }
    return FloatingTodoItem(
      id: normalizedId,
      text: normalizedText,
      completed: value['completed'] == true,
      submitted: value['submitted'] == true,
    );
  }
}

/// Versioned SharedPreferences storage for the floating todo list.
///
/// The key contains the exact source-scoped durable identity (encoded, rather
/// than using a title/project/runtime alias), so equal thread IDs from two
/// Codex Homes or Bridges cannot share items. Malformed or future-version data
/// is ignored safely.
class FloatingTodoStore {
  const FloatingTodoStore({
    this.preferencesLoader = SharedPreferences.getInstance,
  });

  final Future<SharedPreferences> Function() preferencesLoader;

  static const keyPrefix = 'auxiliary_floating_todos_v1_';
  static const _schemaVersion = 1;

  static String identityFor({
    required BridgeDataSourceIdentity dataSourceIdentity,
    required String provider,
    required String durableSessionId,
  }) {
    final normalizedProvider = provider.trim();
    final normalizedSessionId = durableSessionId.trim();
    if (normalizedProvider.isEmpty || normalizedSessionId.isEmpty) return '';
    return [
      dataSourceIdentity.scopeKeyForProvider(normalizedProvider),
      normalizedProvider,
      normalizedSessionId,
    ].join('\u0000');
  }

  static String preferenceKeyFor(String durableSessionId) {
    final encoded = base64Url
        .encode(Uint8List.fromList(utf8.encode(durableSessionId.trim())))
        .replaceAll('=', '');
    return '$keyPrefix$encoded';
  }

  Future<List<FloatingTodoItem>> load(String durableSessionId) async {
    final identity = durableSessionId.trim();
    if (identity.isEmpty) return const [];
    try {
      final preferences = await preferencesLoader();
      final encoded = preferences.getString(preferenceKeyFor(identity));
      if (encoded == null || encoded.trim().isEmpty) return const [];
      final decoded = jsonDecode(encoded);
      if (decoded is! Map || decoded['version'] != _schemaVersion) {
        return const [];
      }
      final rawItems = decoded['items'];
      if (rawItems is! List) return const [];
      final ids = <String>{};
      final items = <FloatingTodoItem>[];
      for (final raw in rawItems) {
        final item = FloatingTodoItem.fromJson(raw);
        if (item == null || !ids.add(item.id)) continue;
        items.add(item);
        if (items.length >= floatingTodoMaxItems) break;
      }
      return List.unmodifiable(items);
    } catch (_) {
      // Preferences are an optional convenience; corrupt data must never
      // prevent the main conversation or floating dock from opening.
      return const [];
    }
  }

  Future<void> save(
    String durableSessionId,
    Iterable<FloatingTodoItem> items,
  ) async {
    final identity = durableSessionId.trim();
    if (identity.isEmpty) return;
    final bounded = <FloatingTodoItem>[];
    final ids = <String>{};
    for (final item in items) {
      final normalized = FloatingTodoItem.fromJson(item.toJson());
      if (normalized == null || !ids.add(normalized.id)) continue;
      bounded.add(normalized);
      if (bounded.length >= floatingTodoMaxItems) break;
    }
    final payload = jsonEncode({
      'version': _schemaVersion,
      'items': bounded.map((item) => item.toJson()).toList(growable: false),
    });
    try {
      final preferences = await preferencesLoader();
      await preferences.setString(preferenceKeyFor(identity), payload);
    } catch (_) {
      // A failed write should not block interaction; the next mutation can
      // try again and the in-memory list remains usable for this page.
    }
  }
}
