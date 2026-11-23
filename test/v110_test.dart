import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/export.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/people.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'domain_test.dart' show task;
import 'widget_test.dart' show WidgetRepository;

void main() {
  group('Справочник ФИО: данные', () {
    test('Проверка человека и списка задействованных', () {
      Dataset.validateData('person', {
        'id': 'a',
        'name': 'Иванов Иван Иванович',
        'position': 'Сварщик',
      });
      expect(
        () => Dataset.validateData('person', {'id': 'a', 'name': '  '}),
        throwsFormatException,
      );
      Dataset.validateData('task', {
        ...task(),
        'people': ['a', 'b'],
      });
      Dataset.validateData('note', {
        'id': 'n',
        'title': 'Запись',
        'people': ['a'],
      });
      expect(
        () => Dataset.validateData('task', {
          ...task(),
          'people': ['a', 'a'],
        }),
        throwsFormatException,
      );
      expect(
        () => Dataset.validateData('task', {...task(), 'people': 'a'}),
        throwsFormatException,
      );
      expect(
        () => Dataset.validateData('note', {
          'id': 'n',
          'title': 'З',
          'people': [1],
        }),
        throwsFormatException,
      );
    });
    test('Справочник переживает синхронизацию (кодирование снимка)', () {
      final d = Dataset()
        ..write('project', {'id': 'p', 'name': 'П'}, 'A')
        ..write('person', {'id': 'a', 'name': 'Петров Пётр'}, 'A')
        ..write('task', {
          ...task(),
          'people': ['a'],
        }, 'A');
      final back = Dataset.decode(d.encode());
      expect(back.visible('person').single['name'], 'Петров Пётр');
      expect(back.merge(d).visible('task').single['people'], ['a']);
    });
    test('Короткое ФИО и удалённые люди не показываются', () {
      expect(shortName('Иванов Иван Иванович'), 'Иванов И. И.');
      expect(shortName('Петров  пётр'), 'Петров П.');
      expect(shortName('Сидоров'), 'Сидоров');
      final d = Dataset()
        ..write('person', {'id': 'a', 'name': 'Иванов Иван Иванович'}, 'A')
        ..write('person', {'id': 'b', 'name': 'Петров Пётр'}, 'A');
      d.write('person', {'id': 'b', 'name': 'Петров Пётр'}, 'A', deleted: true);
      final t = {
        ...task(),
        'people': ['a', 'b', 'x'],
      };
      expect(involvedNames(d, t), ['Иванов Иван Иванович']);
      expect(involvedNames(d, t, short: true), ['Иванов И. И.']);
    });
    test('Excel: столбец «Задействованные»', () {
      final d = Dataset()
        ..write('project', {'id': 'p', 'name': 'П'}, 'A')
        ..write('person', {'id': 'a', 'name': 'Иванов Иван'}, 'A')
        ..write('person', {'id': 'b', 'name': 'Петров Пётр'}, 'A')
        ..write('task', {
          ...task(),
          'people': ['b', 'a'],
        }, 'A');
      final i = exportHeaders.indexOf('Задействованные');
      expect(i, 3);
      expect(
        (exportRows(d).single[i] as TextCell).value,
        'Петров Пётр\nИванов Иван',
      );
    });
  });

  group('Справочник ФИО: интерфейс', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v110_');
      SharedPreferences.setMockInitialValues({});
      c = AppController(
        WidgetRepository(dir),
        await SharedPreferences.getInstance(),
        notifications: false,
      );
      await c.load();
      await c.save('project', {'id': 'p', 'name': 'Сварка'});
      await c.save('person', {
        'id': 'a',
        'name': 'Иванов Иван Иванович',
        'position': 'Мастер',
      });
      await c.save('person', {'id': 'b', 'name': 'Петров Пётр Петрович'});
      await c.save('task', {...task(id: 't1'), 'title': 'Сварить раму'});
      await c.save('task', {
        ...task(id: 't2'),
        'title': 'Заказать газ',
        'people': ['b'],
      });
    });
    tearDown(() async {
      c.dispose();
      await dir.delete(recursive: true);
    });
    void size(WidgetTester tester, Size s) {
      tester.view.physicalSize = s;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Выбор нескольких ФИО из списка, новое ФИО, фильтр', (
      tester,
    ) async {
      size(tester, const Size(400, 1600));
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Задействованы: Петров П. П.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Сварить раму'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Выбрать ФИО'));
      await tester.tap(find.text('Выбрать ФИО'));
      await tester.pumpAndSettle();
      expect(find.text('Мастер'), findsOneWidget);
      await tester.tap(find.text('Иванов Иван Иванович'));
      await tester.tap(find.text('Петров Пётр Петрович'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Поиск или новое ФИО'),
        'Сидоров  Сидор',
      );
      await tester.pump();
      await tester.tap(find.text('Добавить в справочник: Сидоров Сидор'));
      await settle(tester);
      expect(find.text('Выбор ФИО (3)'), findsOneWidget);
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(find.byType(InputChip), findsNWidgets(3));
      await tester.tap(find.byTooltip('Убрать').first); // Иванов
      await tester.pump();
      await tester.tap(find.text('Сохранить'));
      await settle(tester);
      final t = c.data.visible('task').firstWhere((x) => x['id'] == 't1');
      expect(involvedNames(c.data, t), [
        'Петров Пётр Петрович',
        'Сидоров Сидор',
      ]);
      expect(c.data.visible('person'), hasLength(3));
      expect(
        find.textContaining('Задействованы: Петров П. П., Сидоров С.'),
        findsOneWidget,
      );
      // Filter by person.
      await tester.tap(find.text('Все люди'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сидоров Сидор').last);
      await tester.pumpAndSettle();
      expect(find.text('Сварить раму'), findsOneWidget);
      expect(find.text('Заказать газ'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Справочник в настройках: добавление, дубль, удаление', (
      tester,
    ) async {
      size(tester, const Size(400, 900));
      await tester.pumpWidget(MaterialApp(home: PeoplePage(controller: c)));
      await tester.pumpAndSettle();
      expect(find.textContaining('задач и записей: 1'), findsOneWidget);
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'ФИО'),
        'иванов иван иванович',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Такое ФИО уже есть в справочнике'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'ФИО'),
        'Козлов Кирилл',
      );
      await tester.tap(find.text('Сохранить'));
      await settle(tester);
      expect(find.text('Козлов Кирилл'), findsOneWidget);
      await tester.tap(find.byTooltip('Удалить').at(2)); // Петров (used once)
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Указан в задачах и записях: 1'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await settle(tester);
      expect(find.text('Петров Пётр Петрович'), findsNothing);
      expect(c.data.visible('person').map((p) => p['name']).toSet(), {
        'Иванов Иван Иванович',
        'Козлов Кирилл',
      });
      expect(tester.takeException(), isNull);
    });

    testWidgets('Запись базы знаний с задействованными', (tester) async {
      size(tester, const Size(400, 1600));
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('База знаний').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запись'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Название'),
        'Пуск линии',
      );
      await tester.tap(find.text('Выбрать ФИО'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Иванов Иван Иванович'));
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await settle(tester);
      expect(c.data.visible('note').single['people'], ['a']);
      expect(find.textContaining('Иванов И. И.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
