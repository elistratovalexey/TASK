import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/domain.dart';

Json task({String id = 't', String repeat = 'none', String? due}) => {
  'id': id,
  'projectId': 'p',
  'title': 'Задача',
  'notes': '',
  'priority': 1,
  'done': false,
  'due': due,
  'reminder': null,
  'repeat': repeat,
  'checklist': <Json>[],
};
Dataset base() => Dataset()
  ..write('project', {'id': 'p', 'name': 'Проект'}, 'A')
  ..write('task', task(), 'A');

void main() {
  test('Миграция v1 сохраняет ID и срок, не создаёт напоминания', () {
    final t = task(due: '2026-10-21T12:00:00');
    t.remove('checklist');
    t.remove('repeat');
    t.remove('reminder');
    final raw = jsonEncode({
      'version': 1,
      'projects': [
        {'id': 'p', 'name': 'Проект'},
      ],
      'tasks': [t],
    });
    final migrated = Dataset.migrate(raw);
    expect(migrated.visible('task').single['id'], 't');
    expect(migrated.visible('task').single['due'], '2026-10-21T12:00:00');
    expect(migrated.visible('task').single['reminder'], isNull);
    expect(migrated.visible('task').single['repeat'], 'none');
    expect(Dataset.migrate(raw).encode(), migrated.encode());
  });
  test('Сериализация без потерь', () {
    final b = base();
    expect(Dataset.decode(b.encode()).encode(), b.encode());
  });
  test('Неизвестная версия отвергается', () {
    expect(
      () => Dataset.decode('{"version":99,"records":{}}'),
      throwsFormatException,
    );
  });
  test('Неполный JSON отвергается', () {
    expect(() => Dataset.decode('{"version":2'), throwsFormatException);
  });
  test('Невалидная дата отвергается', () {
    expect(
      () => Dataset().write('task', task(due: 'bad'), 'A'),
      throwsFormatException,
    );
  });
  test('Пустой текст пункта отвергается', () {
    final t = task()
      ..['checklist'] = [
        {'id': 'i', 'text': '', 'done': false},
      ];
    expect(() => Dataset().write('task', t, 'A'), throwsFormatException);
  });
  test('Повторение без срока отвергается', () {
    expect(
      () => Dataset().write('task', task(repeat: 'daily'), 'A'),
      throwsFormatException,
    );
  });
  test('Причинно более новая правка замещает старую', () {
    final a = base();
    final b = a.copy()..write('task', {...task(), 'title': 'Новая'}, 'B');
    final merged = a.merge(b);
    expect(merged.conflicts, isEmpty);
    expect(merged.visible('task').single['title'], 'Новая');
  });
  test('Параллельные правки не теряются', () {
    final b = base();
    final a = b.copy()..write('task', {...task(), 'title': 'С ПК'}, 'A');
    final phone = b.copy()
      ..write('task', {...task(), 'title': 'С телефона'}, 'B');
    final merged = a.merge(phone);
    expect(merged.conflicts, ['task:t']);
    expect(merged.records['task:t']!.map((v) => v['data']['title']).toSet(), {
      'С ПК',
      'С телефона',
    });
    expect(a.merge(phone).encode(), phone.merge(a).encode());
  });
  test('Слияние идемпотентно и ассоциативно', () {
    final b = base();
    final a = b.copy()..write('task', {...task(), 'title': 'A'}, 'A');
    final c = b.copy()..write('task', {...task(), 'title': 'C'}, 'C');
    final d = b.copy()..write('task', {...task(), 'title': 'D'}, 'D');
    expect(a.merge(c).merge(d).encode(), a.merge(c.merge(d)).encode());
    expect(a.merge(a).encode(), a.encode());
  });
  test('Удаление не воскресает от старого снимка', () {
    final old = base();
    final deleted = old.copy()..write('task', task(), 'A', deleted: true);
    expect(deleted.merge(old).visible('task'), isEmpty);
  });
  test('Удаление против редактирования сохраняется как конфликт', () {
    final old = base();
    final deleted = old.copy()..write('task', task(), 'A', deleted: true);
    final edit = old.copy()..write('task', {...task(), 'notes': 'Правка'}, 'B');
    expect(deleted.merge(edit).conflicts, ['task:t']);
  });
  test('Выбранная версия доминирует обе конфликтующие ветки', () {
    final old = base();
    final a = old.copy()..write('task', {...task(), 'title': 'A'}, 'A');
    final b = old.copy()..write('task', {...task(), 'title': 'B'}, 'B');
    final merged = a.merge(b)
      ..write('task', {...task(), 'title': 'Выбрано'}, 'A');
    expect(merged.merge(a).merge(b).conflicts, isEmpty);
    expect(merged.merge(b).visible('task').single['title'], 'Выбрано');
  });
  test('31 января -> февраль -> 31 марта', () {
    final feb = nextOccurrence(DateTime(2027, 1, 31, 9), 'monthly', 31);
    expect(feb, DateTime(2027, 2, 28, 9));
    expect(nextOccurrence(feb, 'monthly', 31), DateTime(2027, 3, 31, 9));
  });
  test('Високосный февраль', () {
    expect(
      nextOccurrence(DateTime(2028, 1, 31, 9), 'monthly', 31),
      DateTime(2028, 2, 29, 9),
    );
  });
  test('Ежедневное и еженедельное повторение через границу года', () {
    expect(
      nextOccurrence(DateTime(2026, 12, 31, 9), 'daily', 31),
      DateTime(2027, 1, 1, 9),
    );
    expect(
      nextOccurrence(DateTime(2026, 12, 31, 9), 'weekly', 31),
      DateTime(2027, 1, 7, 9),
    );
  });
  test('Выполнение создаёт следующий экземпляр, сбрасывает чек-лист', () {
    final t =
        task(repeat: 'daily', due: DateTime(2026, 10, 20, 12).toIso8601String())
          ..['reminder'] = DateTime(2026, 10, 20, 11).toIso8601String()
          ..['checklist'] = [
            {'id': 'i', 'text': 'Проверить', 'done': true},
          ];
    final d = Dataset()..write('task', t, 'A');
    d.complete(t, 'A');
    final next = d.visible('task').firstWhere((t) => !t['done']);
    expect(DateTime.parse(next['due']).toLocal(), DateTime(2026, 10, 21, 12));
    expect(
      DateTime.parse(next['reminder']).toLocal(),
      DateTime(2026, 10, 21, 11),
    );
    expect(next['checklist'].single['done'], false);
    final done = d.visible('task').firstWhere((t) => t['done']);
    d.complete(done, 'A');
    d.complete(d.visible('task').firstWhere((t) => t['id'] == done['id']), 'A');
    expect(d.visible('task'), hasLength(2));
  });
  test('Два устройства не создают два ID следующего экземпляра', () {
    final t = task(repeat: 'daily', due: '2026-10-20T09:00:00');
    final original = Dataset()..write('task', t, 'A');
    final a = original.copy()..complete(t, 'A');
    final b = original.copy()..complete(t, 'B');
    expect(a.merge(b).records.length, 2);
  });
  test('Неверный ключ записи отвергается', () {
    final json = jsonDecode(base().encode());
    json['records']['task:t'][0]['id'] = 'different';
    expect(() => Dataset.decode(jsonEncode(json)), throwsFormatException);
  });
}
