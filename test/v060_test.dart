import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'domain_test.dart' show base, task;
import 'widget_test.dart' show WidgetRepository;

void main() {
  group('Время выполнения', () {
    test('Формат длительности', () {
      expect(durationLabel(const Duration(seconds: 20)), 'меньше минуты');
      expect(durationLabel(const Duration(minutes: 45)), '45 мин');
      expect(
        durationLabel(const Duration(hours: 3, minutes: 20)),
        '3 ч 20 мин',
      );
      expect(durationLabel(const Duration(hours: 5)), '5 ч');
      expect(
        durationLabel(const Duration(days: 2, hours: 4, minutes: 9)),
        '2 дн. 4 ч',
      );
    });
    test('Затраченное время и проверка порядка', () {
      final t = {
        ...task(),
        'startedAt': '2026-10-21T06:00:00.000Z',
        'finishedAt': '2026-10-21T09:30:00.000Z',
      };
      Dataset.validateData('task', t);
      expect(spentTime(t), const Duration(hours: 3, minutes: 30));
      expect(workLabel(t), 'Выполнено за 3 ч 30 мин');
      expect(
        () => Dataset.validateData('task', {
          ...t,
          'finishedAt': '2026-10-21T05:00:00.000Z',
        }),
        throwsFormatException,
      );
    });
    test(
      'Отметка «выполнено» ставит окончание, повторное открытие снимает',
      () {
        final d = base();
        final t = {...task(), 'startedAt': '2026-10-21T06:00:00.000Z'};
        d.write('task', t, 'A');
        d.complete(t, 'A', now: DateTime.utc(2026, 10, 21, 8, 15));
        final done = d.visible('task').single;
        expect(done['finishedAt'], '2026-10-21T08:15:00.000Z');
        expect(workLabel(done), 'Выполнено за 2 ч 15 мин');
        d.complete(done, 'A');
        final open = d.visible('task').single;
        expect(open['finishedAt'], isNull);
        expect(open['startedAt'], '2026-10-21T06:00:00.000Z');
      },
    );
    test('Начало в будущем не ломает отметку выполнения', () {
      final d = base();
      final t = {...task(), 'startedAt': '2030-01-01T00:00:00.000Z'};
      d.write('task', t, 'A');
      d.complete(t, 'A', now: DateTime.utc(2026, 10, 21));
      expect(spentTime(d.visible('task').single), Duration.zero);
    });
    test('Следующий экземпляр повторяющейся задачи сохраняет время дня', () {
      // 1.3.3: начало до срока переносится вместе со сроком; окончание,
      // поставленное при отметке «выполнено» после срока, — нет.
      final d = base();
      final t = {
        ...task(repeat: 'daily', due: '2026-10-21T10:00:00.000Z'),
        'startedAt': '2026-10-21T06:00:00.000Z',
      };
      d.write('task', t, 'A');
      d.complete(t, 'A');
      final next = d.visible('task').firstWhere((x) => x['done'] == false);
      expect(next['startedAt'], '2026-10-22T06:00:00.000Z');
      expect(next['finishedAt'], isNull);
      // Начало, поставленное уже после срока, не переносится.
      final d2 = base();
      final late = {...t, 'startedAt': '2026-10-21T11:00:00.000Z'};
      d2.write('task', late, 'A');
      d2.complete(late, 'A');
      final n2 = d2.visible('task').firstWhere((x) => x['done'] == false);
      expect(n2['startedAt'], isNull);
    });
    test('В работе: показывается прошедшее время', () {
      final t = {...task(), 'startedAt': '2026-10-21T06:00:00.000Z'};
      expect(
        workLabel(t, now: DateTime.utc(2026, 10, 21, 7, 5)),
        startsWith('В работе 1 ч 5 мин'),
      );
    });
  });

  group('Интерфейс', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('t6_');
      SharedPreferences.setMockInitialValues({});
      c = AppController(
        WidgetRepository(dir),
        await SharedPreferences.getInstance(),
        notifications: false,
      );
      await c.load();
    });
    tearDown(() async {
      c.dispose();
      await dir.delete(recursive: true);
    });

    testWidgets('Кнопка «Начать», отметка выполнения и время в карточке', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await c.save('project', {'id': 'p', 'name': 'Сварка'});
        await c.save('task', {...task(id: 'a'), 'title': 'Сварить раму'});
      });
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Начать выполнение'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(c.data.visible('task').single['startedAt'], isNotNull);
      expect(find.textContaining('В работе'), findsOneWidget);
      expect(find.byTooltip('Начать выполнение'), findsNothing);
      await tester.tap(find.byType(Checkbox).first);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final t = c.data.visible('task').single;
      expect(t['done'], isTrue);
      expect(t['finishedAt'], isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Редактор: время начала/окончания и затраченное время', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Json? saved;
      final old = {
        ...task(),
        'startedAt': '2026-10-21T06:00:00.000Z',
        'finishedAt': '2026-10-21T08:45:00.000Z',
      };
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
                  old: old,
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Затрачено: 2 ч 45 мин'), findsOneWidget);
      // Remove finish: the task is "in work" again.
      await tester.tap(find.text('Убрать').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Затрачено'), findsNothing);
      expect(find.textContaining('В работе:'), findsOneWidget);
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(saved!['startedAt'], '2026-10-21T06:00:00.000Z');
      expect(saved!['finishedAt'], isNull);
    });
  });
}
