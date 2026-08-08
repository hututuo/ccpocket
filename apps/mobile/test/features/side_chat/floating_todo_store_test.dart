import 'dart:convert';

import 'package:ccpocket/features/side_chat/state/floating_todo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('uses the exact durable identity and keeps insertion order', () async {
    final store = const FloatingTodoStore();
    await store.save('thread-main', const [
      FloatingTodoItem(id: 'one', text: 'First'),
      FloatingTodoItem(id: 'two', text: 'Second', completed: true),
    ]);
    await store.save('thread-other', const [
      FloatingTodoItem(id: 'other', text: 'Other'),
    ]);

    expect((await store.load('thread-main')).map((item) => item.id), [
      'one',
      'two',
    ]);
    expect((await store.load('thread-other')).single.text, 'Other');
    expect(await store.load('thread-missing'), isEmpty);
    expect(
      FloatingTodoStore.preferenceKeyFor('thread-main'),
      isNot(FloatingTodoStore.preferenceKeyFor('thread-other')),
    );
  });

  test('corrupt or future-version data falls back to an empty list', () async {
    final preferences = await SharedPreferences.getInstance();
    final key = FloatingTodoStore.preferenceKeyFor('thread-main');
    await preferences.setString(key, '{not json');
    expect(await const FloatingTodoStore().load('thread-main'), isEmpty);

    await preferences.setString(key, jsonEncode({'version': 99, 'items': []}));
    expect(await const FloatingTodoStore().load('thread-main'), isEmpty);
  });

  test('invalid, duplicate and oversized records are ignored safely', () async {
    final preferences = await SharedPreferences.getInstance();
    final key = FloatingTodoStore.preferenceKeyFor('thread-main');
    await preferences.setString(
      key,
      jsonEncode({
        'version': 1,
        'items': [
          {'id': 'one', 'text': 'First'},
          {'id': 'one', 'text': 'Duplicate'},
          {'id': '', 'text': 'Missing id'},
          {'id': 'too-long', 'text': 'x' * (floatingTodoMaxTextCharacters + 1)},
          'not an object',
        ],
      }),
    );
    final items = await const FloatingTodoStore().load('thread-main');
    expect(items, hasLength(1));
    expect(items.single.text, 'First');
  });
}
