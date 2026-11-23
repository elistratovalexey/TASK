import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WidgetRepository extends Repository {
  Dataset value = Dataset();
  WidgetRepository(super.directory);
  @override
  Future<Dataset> load(SharedPreferences prefs) async => value.copy();
  @override
  Future<void> save(Dataset data) async {
    value = data.copy();
  }
}

void main() {
  late Directory directory;
  late AppController c;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('project_widgets_');
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
  testWidgets('Пустое приложение открывается на русском', (tester) async {
    await tester.pumpWidget(TaskApplication(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Мои проекты'), findsOneWidget);
    expect(find.text('Все проекты'), findsOneWidget);
    expect(find.text('Задача'), findsOneWidget);
    expect(
      find.text('Задач нет. Создайте проект и добавьте задачу.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('Создание проекта и задачи с чек-листом', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TaskApplication(controller: c));
    await tester.tap(find.byTooltip('Создать проект'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Сварочный комплекс');
    await tester.tap(find.text('Сохранить'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(c.data.visible('project'), hasLength(1));
    await tester.tap(find.text('Задача'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Название задачи'),
      'Согласовать ТЗ',
    );
    await tester.ensureVisible(find.widgetWithText(TextField, 'Новый пункт'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Новый пункт'),
      'Проверить чертёж',
    );
    await tester.ensureVisible(find.byTooltip('Добавить пункт'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить пункт'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(c.data.visible('task').single['title'], 'Согласовать ТЗ');
    expect(c.data.visible('task').single['checklist'], hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('Редактор требует срок для повторения', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDialog<Json>(
                context: ctx,
                builder: (_) => TaskEditor(
                  controller: c,
                  projects: const [
                    {'id': 'p', 'name': 'Проект'},
                  ],
                  projectId: 'p',
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Название задачи'),
      'Задача',
    );
    await tester.ensureVisible(find.text('Не повторять'));
    await tester.tap(find.text('Не повторять'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ежедневно').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Укажите срок для повторяющейся задачи'), findsOneWidget);
    expect(find.byType(TaskEditor), findsOneWidget);
  });
  testWidgets('Узкий экран не переполняется', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TaskApplication(controller: c));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('Тёмная тема применяется из настроек', (tester) async {
    await c.prefs.setString('theme', 'dark');
    await tester.pumpWidget(TaskApplication(controller: c));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });
  testWidgets('Редактор с вложениями и подпроектами на узком экране', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDialog<Json>(
                context: ctx,
                builder: (_) => TaskEditor(
                  controller: c,
                  projects: const [
                    {
                      'id': 'p',
                      'name': 'Очень длинное название проекта завода',
                    },
                    {
                      'id': 's',
                      'name': 'Подпроект с длинным именем',
                      'parentId': 'p',
                    },
                  ],
                  projectId: 's',
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.text('Вложения (0)'), findsOneWidget);
    expect(find.text('Голос'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
