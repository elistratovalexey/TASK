import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/sketch.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain_test.dart' show base, task;
import 'widget_test.dart' show WidgetRepository;

void main() {
  group('История сроков', () {
    final t0 = DateTime.utc(2026, 10, 21, 9);
    test('Новая задача со сроком — запись «назначен»', () {
      final r = withDueHistory(
        null,
        task(due: '2026-10-25T10:00:00.000Z'),
        now: t0,
      );
      expect(r['dueHistory'], hasLength(1));
      expect(r['dueHistory'][0]['from'], isNull);
      Dataset.validateData('task', r);
    });
    test('Без срока и без изменения срока история не растёт', () {
      expect(withDueHistory(null, task())['dueHistory'], isEmpty);
      final old = withDueHistory(null, task(due: '2026-10-25T10:00:00.000Z'));
      final same = withDueHistory(old, {...old, 'title': 'Новое имя'});
      expect(same['dueHistory'], hasLength(1));
      // The same moment written in another time zone is not a change.
      final tz = withDueHistory(old, {
        ...old,
        'due': '2026-10-25T13:00:00.000+03:00',
      });
      expect(tz['dueHistory'], hasLength(1));
    });
    test('Перенос и снятие срока с причиной', () {
      var t = withDueHistory(null, task(due: '2026-10-25T10:00:00.000Z'));
      t = withDueHistory(t, {
        ...t,
        'due': '2026-10-30T10:00:00.000Z',
      }, reason: ' Задержка поставки ');
      t = withDueHistory(t, {...t, 'due': null});
      final h = t['dueHistory'] as List;
      expect(h, hasLength(3));
      expect(h[1]['reason'], 'Задержка поставки');
      expect(h[2]['to'], isNull);
      expect(h[2].containsKey('reason'), isFalse);
      expect(dueMoves(t), 2);
      expect(dueChangeLabel(h[1]), contains('(+5 дн.)'));
      Dataset.validateData('task', t);
    });
    test('Повреждённая история отклоняется', () {
      expect(
        () => Dataset.validateData('task', {
          ...task(),
          'dueHistory': [
            {'at': 'вчера'},
          ],
        }),
        throwsFormatException,
      );
    });
    test(
      'Следующий экземпляр повторяющейся задачи начинает историю заново',
      () {
        final d = base();
        final t = withDueHistory(
          null,
          task(repeat: 'daily', due: '2026-10-21T10:00:00.000Z'),
        );
        final moved = withDueHistory(t, {
          ...t,
          'due': '2026-10-22T10:00:00.000Z',
        });
        d.write('task', moved, 'A');
        d.complete(moved, 'A');
        final next = d.visible('task').firstWhere((x) => x['done'] == false);
        expect(next['dueHistory'], isEmpty);
      },
    );
  });

  group('База знаний: данные', () {
    test('Запись проходит проверку и синхронизируется', () {
      final a = base()
        ..write('note', {
          'id': 'n',
          'title': 'Настройка KUKA',
          'text': 'Шаг 1',
          'parentId': null,
        }, 'A');
      final b = Dataset.decode(a.encode());
      expect(b.visible('note').single['title'], 'Настройка KUKA');
      final merged = base().merge(b);
      expect(merged.visible('note'), hasLength(1));
    });
    test('Без названия и ссылка на себя — ошибка', () {
      expect(
        () => Dataset.validateData('note', {'id': 'n', 'title': ' '}),
        throwsFormatException,
      );
      expect(
        () => Dataset.validateData('note', {
          'id': 'n',
          'title': 'X',
          'parentId': 'n',
        }),
        throwsFormatException,
      );
    });
    test('Дерево записей с путём по названиям', () {
      final t = ProjectTree([
        {'id': 'a', 'title': 'Роботы'},
        {'id': 'b', 'title': 'KUKA', 'parentId': 'a'},
      ], nameKey: 'title');
      expect(t.path('b'), 'Роботы / KUKA');
    });
  });

  group('База знаний: интерфейс', () {
    late Directory directory;
    late AppController c;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('kb_');
      c = AppController(
        WidgetRepository(directory),
        await SharedPreferences.getInstance(),
        notifications: false,
      );
      await c.load();
    });
    tearDown(() async {
      c.dispose();
      await directory.delete(recursive: true);
    });

    testWidgets('Создание записи и вложенной записи, удаление ветки', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('База знаний').last);
      await tester.pumpAndSettle();
      expect(find.text('Запись'), findsOneWidget);
      await tester.tap(find.text('Запись'));
      await tester.pumpAndSettle();
      expect(find.text('Рисунок'), findsOneWidget);
      expect(find.text('Голос'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Название'),
        'Роботы',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Текст'),
        'Общие сведения',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Роботы'), findsOneWidget);

      await tester.tap(find.byTooltip('Действия'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить вложенную запись'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Название'),
        'KUKA KR 16',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('KUKA KR 16'), findsOneWidget);
      expect(
        c.data
            .visible('note')
            .firstWhere((n) => n['title'] == 'KUKA KR 16')['parentId'],
        c.data.visible('note').firstWhere((n) => n['title'] == 'Роботы')['id'],
      );

      // Search finds nested entry by text and shows its parent.
      await tester.tap(find.byTooltip('Свернуть'));
      await tester.pumpAndSettle();
      expect(find.text('KUKA KR 16'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'kr 16');
      await tester.pumpAndSettle();
      expect(find.text('KUKA KR 16'), findsOneWidget);
      expect(find.text('Роботы'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Действия').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить с вложенными'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(c.data.visible('note'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Рисование и сохранение PNG', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async =>
                  result = await Navigator.of(ctx).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          SketchPage(directory: () async => directory),
                    ),
                  ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final center = tester.getCenter(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is SketchPainter,
        ),
      );
      final g = await tester.startGesture(center);
      await g.moveBy(const Offset(40, 30));
      await g.moveBy(const Offset(40, -10));
      await g.up();
      await tester.pump();
      await tester.tap(find.byTooltip('Отменить'));
      await tester.pump();
      await tester.tap(find.byTooltip('Повторить'));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('Готово'));
        for (var i = 0; i < 50 && result == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      final bytes = File(result!).readAsBytesSync();
      expect(bytes.sublist(1, 4), [0x50, 0x4E, 0x47]); // PNG
      File(result!).deleteSync();
    });

    testWidgets('Редактор задачи показывает историю и поле причины', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var t = withDueHistory(null, task(due: '2026-10-25T10:00:00.000Z'));
      t = withDueHistory(t, {
        ...t,
        'due': '2026-10-30T10:00:00.000Z',
      }, reason: 'Нет деталей');
      Json? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => saved = await showDialog<Json>(
                context: ctx,
                builder: (_) => TaskEditor(
                  controller: c,
                  projects: const [
                    {'id': 'p', 'name': 'Проект'},
                  ],
                  projectId: 'p',
                  old: t,
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('История сроков (2)'), findsOneWidget);
      expect(find.textContaining('Причина изменения'), findsNothing);
      await tester.tap(find.text('Убрать срок'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Причина изменения'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Причина изменения срока (необязательно)',
        ),
        'Отменено заказчиком',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(
        (saved!['dueHistory'] as List).last['reason'],
        'Отменено заказчиком',
      );
      expect((saved!['dueHistory'] as List), hasLength(3));
    });
  });
}
