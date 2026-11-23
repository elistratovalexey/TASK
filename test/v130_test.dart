import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/planner.dart';
import 'package:project_reminders/planner_ui.dart';
import 'package:project_reminders/timeline_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'v100_test.dart' show now, t, iso;
import 'widget_test.dart' show WidgetRepository;

void main() {
  fixedTests();
  late Directory dir;
  late AppController c;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('v130_');
    SharedPreferences.setMockInitialValues({});
    c = AppController(
      WidgetRepository(dir),
      await SharedPreferences.getInstance(),
      notifications: false,
    );
    await c.load();
    await c.save('project', {'id': 'p', 'name': 'Сварка'});
    await c.save('task', t('A', 180, due: DateTime(2026, 10, 22, 12)));
    await c.save('task', t('B', 600));
    // Actual work: done yesterday 16:00 → today 09:30; running since 09:45.
    await c.save('task', {
      ...t('F', 60),
      'done': true,
      'startedAt': iso(DateTime(2026, 10, 21, 16)),
      'finishedAt': iso(DateTime(2026, 10, 22, 9, 30)),
    });
    await c.save('task', {
      ...t('R', 60),
      'startedAt': iso(DateTime(2026, 10, 22, 9, 45)),
    });
  });
  tearDown(() async {
    c.dispose();
    await dir.delete(recursive: true);
  });

  test('Блоки плана, факта и сроки дня', () {
    final plan = c.plan(now: now);
    final day = DateTime(2026, 10, 22);
    final planned = plannedBlocks(plan, day);
    final a = planned.firstWhere((b) => b.task['id'] == 'A');
    expect(
      [a.from, a.to],
      [DateTime(2026, 10, 22, 10, 45), DateTime(2026, 10, 22, 13)],
    );
    expect(a.late, isTrue);
    expect(
      planned.where((b) => b.task['id'] == 'B').single.note,
      'по плану • часть 1 из 3',
    );
    final facts = factBlocks(c.data, day, now);
    expect(facts.map((f) => f.task['id']), ['F', 'R']);
    expect(facts.first.from, day); // cut at midnight
    expect(facts.first.note, 'выполнено');
    expect([facts.last.to, facts.last.note], [now, 'выполняется']);
    expect(factBlocks(c.data, DateTime(2026, 10, 21), now).single.to, day);
    expect(factBlocks(c.data, DateTime(2026, 10, 23), now), isEmpty);
    expect(dueOn(c.data, day).single['id'], 'A');
  });

  group('Интерфейс шкалы', () {
    void size(WidgetTester tester, Size s) {
      tester.view.physicalSize = s;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets(
      'Нажатие на день открывает шкалу; дни листаются; блок открывает задачу',
      (tester) async {
        size(tester, const Size(380, 860));
        Json? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => CalendarDialog(
                    controller: c,
                    now: now,
                    onOpen: (x) => opened = x,
                  ),
                ),
                child: const Text('cal'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('cal'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('day-2026-10-22')));
        await tester.pumpAndSettle();
        expect(find.text('Сегодня, Чт, 22.10.2026'), findsOneWidget);
        expect(find.textContaining('Занято 7 ч 15 мин из 8 ч'), findsOneWidget);
        expect(find.text('План (4)'), findsOneWidget);
        expect(find.text('Факт (2)'), findsOneWidget);
        expect(
          find.text('Срок 12:00: Задача A — не успевается'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('timeline-now')), findsOneWidget);
        expect(find.text('Перерыв'), findsOneWidget);
        expect(
          find.textContaining(
            '10:45–13:00 • Сварка • по плану • часть 1 из 2 • не успевается',
          ),
          findsOneWidget,
        );
        // Scrolled to the first event (midnight: fact block F), visible block.
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Следующий день'));
        await tester.pumpAndSettle();
        expect(find.text('Пт, 23.10.2026'), findsOneWidget);
        expect(find.textContaining('часть 2 из 3'), findsOneWidget);
        expect(find.byKey(const ValueKey('timeline-now')), findsNothing);
        await tester.tap(find.byTooltip('Следующий день'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Выходной — задачи не планируются'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Предыдущий день'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Задача B').first);
        await tester.pumpAndSettle();
        expect(opened?['id'], 'B');
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

void fixedTests() {
  test(
    'Задача с заданным началом стоит на своём времени; остальные — вокруг',
    () {
      const ws = WorkSchedule();
      final now = DateTime(2026, 10, 22, 10, 7); // Чт
      final tasks = [
        {
          ...t('M', 60, due: DateTime(2026, 10, 22, 12, 45)),
          'startedAt': iso(DateTime(2026, 10, 22, 11, 45)),
        },
        {...t('X', 90, due: DateTime(2026, 10, 22, 16))},
        {
          ...t('H', 40, due: DateTime(2026, 10, 25, 18, 30)),
          'startedAt': iso(DateTime(2026, 10, 25, 17, 30)),
        }, // Вс, личное
      ];
      final plan = buildPlan(tasks, ws, now);
      Slot one(String id) =>
          plan.items.firstWhere((i) => i.task['id'] == id).slots.single;
      expect(
        [one('M').from, one('M').to],
        [DateTime(2026, 10, 22, 11, 45), DateTime(2026, 10, 22, 12, 45)],
      );
      expect(one('M').fixed, isTrue);
      expect(
        [one('H').from, one('H').to],
        [DateTime(2026, 10, 25, 17, 30), DateTime(2026, 10, 25, 18, 10)],
      );
      // X: 10:15–11:45 fits exactly before the fixed meeting.
      final x = plan.items.firstWhere((i) => i.task['id'] == 'X').slots;
      expect(
        [x.first.from, x.last.to],
        [DateTime(2026, 10, 22, 10, 15), DateTime(2026, 10, 22, 11, 45)],
      );
      expect(plan.suggestions, isEmpty);
      expect(plan.load(DateTime(2026, 10, 25)), 40);
      // A floating task must not overlap a fixed one.
      final y = buildPlan(
        [...tasks, t('Y', 120)],
        ws,
        now,
      ).items.firstWhere((i) => i.task['id'] == 'Y').slots;
      expect(y.first.from, DateTime(2026, 10, 22, 12, 45));
      expect(y.first.to, DateTime(2026, 10, 22, 13));
      expect(y.last.from, DateTime(2026, 10, 22, 14));
      // Planned start and finish (not done yet) — fixed; done — not planned.
      final z = {...t('Z', 10), 'startedAt': iso(now), 'finishedAt': iso(now)};
      expect(fixedStart(z), now);
      expect(fixedStart({...z, 'done': true}), isNull);
    },
  );

  test('Пересекающиеся блоки встают рядом', () {
    TimelineBlock b(int h1, int m1, int h2, int m2) => TimelineBlock(
      const {'id': 'x', 'title': 'x'},
      DateTime(2026, 1, 1, h1, m1),
      DateTime(2026, 1, 1, h2, m2),
    );
    final list = [
      b(9, 0, 10, 0),
      b(9, 30, 10, 30),
      b(10, 0, 11, 0),
      b(12, 0, 12, 5),
      b(12, 5, 12, 10),
    ];
    final cols = columnsFor(list);
    expect(cols.sublist(0, 3).map((c) => c.cols), [2, 2, 2]);
    expect(cols.sublist(0, 3).map((c) => c.col), [0, 1, 0]);
    expect(cols.sublist(3).map((c) => c.cols), [1, 1]);
    // Drawn at least 20 minutes tall → the 5-minute blocks go side by side.
    expect(columnsFor(list, minMinutes: 20).sublist(3).map((c) => c.col), [
      0,
      1,
    ]);
  });
}
