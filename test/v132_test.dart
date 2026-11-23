import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/export.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/planner.dart';
import 'package:project_reminders/timeline_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'v100_test.dart' show now, t, iso;
import 'widget_test.dart' show WidgetRepository;

void main() {
  late Directory dir;
  late AppController c;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('v132_');
    SharedPreferences.setMockInitialValues({});
    c = AppController(
      WidgetRepository(dir),
      await SharedPreferences.getInstance(),
      notifications: false,
    );
    await c.load();
    await c.save('project', {'id': 'p', 'name': 'Сварка'});
    await c.save('task', {
      ...t('A', 120, due: DateTime(2026, 10, 22, 12)),
      'title': 'Задача A',
    });
    await c.save('task', {
      ...t('H', 240, due: DateTime(2026, 10, 22, 11)),
      'title': 'Скрытая',
      'timeline': false,
      'startedAt': iso(DateTime(2026, 10, 22, 9)),
    });
  });
  tearDown(() async {
    c.dispose();
    await dir.delete(recursive: true);
  });

  test('Задача без галочки не планируется и не попадает на шкалу', () {
    expect(onTimeline({'id': 'x'}), isTrue);
    expect(onTimeline({'id': 'x', 'timeline': false}), isFalse);
    expect(
      () => Dataset.validateData('task', {...t('Z', 60), 'timeline': 'нет'}),
      throwsFormatException,
    );
    final plan = c.plan(now: now);
    expect(plan.items.map((i) => i.task['id']), ['A']);
    // A: 10:15–12:15 — late; the hidden task does not take time before it.
    expect(plan.suggestions.single.task['id'], 'A');
    expect(plan.items.single.finish, DateTime(2026, 10, 22, 12, 15));
  });

  test('Шкала: ни плана, ни факта, ни срока для скрытой задачи', () {
    final day = DateTime(2026, 10, 22);
    expect(plannedBlocks(c.plan(now: now), day).map((b) => b.task['id']), [
      'A',
    ]);
    expect(factBlocks(c.data, day, now), isEmpty);
    expect(dueOn(c.data, day).map((x) => x['id']), ['A']);
    final i = exportHeaders.indexOf('На шкале');
    final rows = exportRows(c.data);
    expect(rows.map((r) => (r[i] as TextCell).value).toSet(), {'Да', 'Нет'});
  });

  testWidgets('Галочка в редакторе и пометка в карточке', (tester) async {
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TaskApplication(controller: c));
    await tester.pumpAndSettle();
    expect(find.textContaining('Не на временной шкале'), findsOneWidget);
    await tester.tap(find.text('Задача A'));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('timeline-check'));
    await tester.ensureVisible(box);
    expect(tester.widget<CheckboxListTile>(box).value, isTrue);
    await tester.tap(box);
    await tester.pump();
    await tester.tap(find.text('Сохранить'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(
      c.data.visible('task').firstWhere((x) => x['id'] == 'A')['timeline'],
      isFalse,
    );
    expect(find.textContaining('Не на временной шкале'), findsNWidgets(2));
    expect(c.plan(now: now).items, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
