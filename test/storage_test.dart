import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain_test.dart' show base, task;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Repository repo;
  late SharedPreferences prefs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('project_storage_');
    repo = Repository(directory);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() async => directory.delete(recursive: true));
  test('Сохранение и повторная загрузка', () async {
    await repo.save(base());
    expect((await repo.load(prefs)).visible('task').single['title'], 'Задача');
  });
  test('Автокопия содержит предыдущее состояние', () async {
    final first = base();
    await repo.save(first);
    await repo.save(
      first.copy()..write('task', {...task(), 'title': 'Новая'}, 'A'),
    );
    final files = await repo.backups.list().toList();
    expect(files, hasLength(1));
    expect(
      Dataset.decode(await File(files.single.path).readAsString()).encode(),
      first.encode(),
    );
  });
  test('Повреждённый основной файл не затирается', () async {
    await repo.current.writeAsString('broken');
    await expectLater(repo.load(prefs), throwsFormatException);
    await expectLater(repo.save(base()), throwsFormatException);
    expect(await repo.current.readAsString(), 'broken');
  });
  test('Восстановление после прерванного переименования', () async {
    final b = base();
    await repo.previous.writeAsString(b.encode());
    expect((await repo.load(prefs)).encode(), b.encode());
    expect(await repo.current.exists(), true);
  });
  test('Хранится не больше 30 автокопий', () async {
    final b = base();
    for (var i = 0; i < 34; i++) {
      await repo.backup(b);
    }
    expect(await repo.backups.list().length, 30);
  });
  test(
    'Восстановление копии является новой синхронизируемой правкой',
    () async {
      final old = base();
      final now = old.copy()
        ..write('task', {...task(), 'title': 'Изменено'}, 'B')
        ..write('task', task(id: 'extra'), 'B');
      final restored = repo.restore(now, old, 'A');
      final resynced = restored.merge(now);
      expect(resynced.visible('task'), hasLength(1));
      expect(resynced.visible('task').single['title'], 'Задача');
      expect(resynced.conflicts, isEmpty);
    },
  );
  test('Копия с конфликтами требует разрешения, не теряет варианты', () {
    final b = base();
    final a = b.copy()..write('task', {...task(), 'title': 'A'}, 'A');
    final phone = b.copy()..write('task', {...task(), 'title': 'B'}, 'B');
    expect(() => repo.restore(b, a.merge(phone), 'A'), throwsFormatException);
  });
}
