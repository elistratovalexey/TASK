import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/planner.dart';
import 'package:project_reminders/rich_text.dart';
import 'package:project_reminders/timeline_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'v100_test.dart' show t, iso;
import 'widget_test.dart' show WidgetRepository;

String u(DateTime d) => d.toUtc().toIso8601String();

void main() {
  group('Ежедневные задачи с заданным временем', () {
    const ws = WorkSchedule(
      start: 510,
      end: 1050,
      breakStart: 780,
      breakEnd: 825,
    );
    final now = DateTime(2026, 10, 29, 9, 20);
    Json lunch(DateTime day) => {
      ...t('L', 30, due: DateTime(day.year, day.month, day.day, 10, 30)),
      'title': 'Ланч',
      'repeat': 'daily',
      'startedAt': iso(DateTime(day.year, day.month, day.day, 10)),
      'finishedAt': iso(DateTime(day.year, day.month, day.day, 10, 30)),
    };
    test('Ланч 10:00–10:30 стоит на своём времени, без переноса срока', () {
      final tasks = [
        lunch(now),
        {...t('S', 120, due: DateTime(2026, 10, 29, 12))},
      ];
      final plan = buildPlan(tasks, ws, now);
      final l = plan.items.firstWhere((i) => i.task['id'] == 'L').slots.single;
      expect(
        [l.from, l.to],
        [DateTime(2026, 10, 29, 10), DateTime(2026, 10, 29, 10, 30)],
      );
      expect(l.fixed, isTrue);
      expect(plan.suggestions.where((s) => s.task['id'] == 'L'), isEmpty);
      // Плановая задача обходит ланч: 9:30–10:00 и 10:30–12:00.
      final s = plan.items.firstWhere((i) => i.task['id'] == 'S').slots;
      expect(
        [s.first.from, s.first.to],
        [DateTime(2026, 10, 29, 9, 30), DateTime(2026, 10, 29, 10)],
      );
      expect(
        [s.last.from, s.last.to],
        [DateTime(2026, 10, 29, 10, 30), DateTime(2026, 10, 29, 12)],
      );
    });

    test('После выполнения завтрашний ланч снова 10:00–10:30', () {
      final d = Dataset();
      final l = lunch(now);
      d.write('task', l, 'A');
      d.complete(l, 'A', now: DateTime(2026, 10, 29, 10, 40));
      final next = d.visible('task').firstWhere((x) => x['done'] == false);
      expect(
        DateTime.parse(next['due']).toLocal(),
        DateTime(2026, 10, 30, 10, 30),
      );
      expect(
        DateTime.parse(next['startedAt']).toLocal(),
        DateTime(2026, 10, 30, 10),
      );
      expect(
        DateTime.parse(next['finishedAt']).toLocal(),
        DateTime(2026, 10, 30, 10, 30),
      );
      final plan = buildPlan(
        d.visible('task').where((x) => x['done'] != true).toList(),
        ws,
        now,
      );
      final s = plan.items.single.slots.single;
      expect(
        [s.from, s.to],
        [DateTime(2026, 10, 30, 10), DateTime(2026, 10, 30, 10, 30)],
      );
    });

    test('Факт: плановое время ещё не выполненной задачи — не факт', () {
      final data = Dataset()..write('task', lunch(now), 'A');
      expect(factBlocks(data, now, now), isEmpty);
      final later = DateTime(2026, 10, 29, 10, 10);
      final f = factBlocks(data, now, later).single;
      expect(
        [f.from, f.to, f.note],
        [DateTime(2026, 10, 29, 10), later, 'выполняется'],
      );
    });
  });

  test('Рассчитать начало: срок минус оценка', () {
    const ws = WorkSchedule(start: 510, end: 1050, hasBreak: false);
    expect(
      startBeforeDue(DateTime(2026, 10, 29, 10, 30), 30, ws),
      DateTime(2026, 10, 29, 10),
    );
    expect(
      startBeforeDue(DateTime(2026, 10, 30, 7), 120, ws),
      DateTime(2026, 10, 30, 5),
    );
    // 2 рабочих дня (16 ч) до Пн 12:00: Пн 8:30–12:00 (3 ч 30), Пт 9 ч, Чт 3 ч 30 → Чт 14:00.
    expect(
      startBeforeDue(DateTime(2026, 11, 2, 12), 960, ws),
      DateTime(2026, 10, 29, 14),
    );
  });

  group('Форматирование текста', () {
    test('Стили выделения, ввод внутри и сохранение', () {
      final c = RichTextController(text: 'Привет мир');
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
      c.toggleBold(c.selection);
      c.setColor(c.selection, richColors.first);
      expect(
        c.styles.take(6).every((s) => s.bold && s.color == richColors.first),
        isTrue,
      );
      expect(c.styles[7].isPlain, isTrue);
      // Ввод в середине жирного слова — тоже жирный.
      c.value = const TextEditingValue(
        text: 'Привеет мир',
        selection: TextSelection.collapsed(offset: 6),
      );
      expect(c.styles[5].bold, isTrue);
      expect(c.styles.length, 11);
      // Повторное нажатие снимает полужирный.
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
      c.toggleBold(c.selection);
      expect(c.styles.take(7).any((s) => s.bold), isFalse);
      c.toggleItalic(c.selection);
      c.toggleUnderline(c.selection);
      c.setFont(c.selection, 'serif');
      c.setSize(c.selection, 18);
      final f = c.format!;
      final back = RichTextController(text: c.text, format: f);
      expect(back.styles, c.styles);
      expect(
        back.styles.first,
        const CharStyle(
          italic: true,
          underline: true,
          color: 0xFFE53935,
          font: 'serif',
          size: 18,
        ),
      );
      // Текст изменён старой версией — форматирование не применяется.
      expect(
        RichTextController(
          text: '${c.text}!',
          format: f,
        ).styles.every((s) => s.isPlain),
        isTrue,
      );
      expect(() => validateTextFormat(f), returnsNormally);
      expect(
        () => validateTextFormat({'md5': 'x', 'runs': 1}),
        throwsFormatException,
      );
    });

    test('Кнопка без выделения задаёт стиль для нового текста', () {
      final c = RichTextController(text: 'ab');
      c.selection = const TextSelection.collapsed(offset: 2);
      c.toggleBold(c.selection);
      c.value = const TextEditingValue(
        text: 'abcd',
        selection: TextSelection.collapsed(offset: 4),
      );
      expect(c.styles.map((s) => s.bold), [false, false, true, true]);
      c.selection = const TextSelection.collapsed(offset: 1);
      c.value = const TextEditingValue(
        text: 'axbcd',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(c.styles[1].bold, isFalse);
    });

    test('Гиперссылки', () {
      final c = RichTextController(text: 'см. сайт тут');
      c.setLink(4, 8, normalizeLink('weldex.ru'));
      expect(c.linkAt(6), (4, 8, 'https://weldex.ru'));
      expect(c.linkAt(8), (
        4,
        8,
        'https://weldex.ru',
      )); // курсор сразу после ссылки
      expect(c.linkAt(1), isNull);
      // Ввод после ссылки не продолжает ссылку.
      c.value = const TextEditingValue(
        text: 'см. сайт! тут',
        selection: TextSelection.collapsed(offset: 9),
      );
      expect(c.styles[8].link, isNull);
      c.insertLink(10, 13, 'почта', normalizeLink('a@b.ru'));
      expect(c.text, 'см. сайт! почта');
      expect(c.linkAt(12)!.$3, 'mailto:a@b.ru');
      expect(normalizeLink('file:///D:/x.pdf'), 'file:///D:/x.pdf');
      c.setLink(4, 8, null);
      expect(c.linkAt(5), isNull);
    });

    test('Обрезка пробелов при сохранении заметок задачи', () {
      final c = RichTextController(text: '  жирно  ');
      c.selection = const TextSelection(baseOffset: 2, extentOffset: 7);
      c.toggleBold(c.selection);
      final back = RichTextController(
        text: c.text.trim(),
        format: c.trimmedFormat,
      );
      expect(back.styles.every((s) => s.bold), isTrue);
    });
  });

  group('Интерфейс', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v133_');
      SharedPreferences.setMockInitialValues({});
      c = AppController(
        WidgetRepository(dir),
        await SharedPreferences.getInstance(),
        notifications: false,
      );
      await c.load();
      await c.save('project', {'id': 'p', 'name': 'Сварка'});
      await c.save('task', {
        ...t('A', 90, due: DateTime(2026, 11, 3, 15)),
        'title': 'Задача A',
        'notes': 'важно позвонить',
      });
    });
    tearDown(() async {
      c.dispose();
      await dir.delete(recursive: true);
    });

    testWidgets('Кнопки «Рассчитать» и форматирование заметок в задаче', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Задача A'));
      await tester.pumpAndSettle();
      expect(find.text('Начало выполнения: 03.11.2026 13:30'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('calc-start')));
      await tester.pump();
      expect(find.text('Начало выполнения: 03.11.2026 13:30'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('calc-reminder')));
      await tester.pump();
      expect(find.text('Напоминание: 03.11.2026 13:30'), findsOneWidget);
      // Выделяем «важно» и делаем полужирным красным.
      final notes = find.descendant(
        of: find.byKey(const ValueKey('task-notes')),
        matching: find.byType(EditableText),
      );
      final ctl =
          tester.widget<EditableText>(notes).controller as RichTextController;
      await tester.tap(find.byKey(const ValueKey('task-notes')));
      await tester.pump();
      ctl.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pump();
      await tester.tap(find.byTooltip('Полужирный'));
      await tester.pump();
      expect(
        ctl.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      await tester.tap(find.byKey(const ValueKey('rich-color')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('rich-color-${richColors.first}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final saved = c.data.visible('task').firstWhere((x) => x['id'] == 'A');
      expect(
        DateTime.parse(saved['startedAt']).toLocal(),
        DateTime(2026, 11, 3, 13, 30),
      );
      expect(
        DateTime.parse(saved['reminder']).toLocal(),
        DateTime(2026, 11, 3, 13, 30),
      );
      final st = decodeFormat(saved['notesFmt'], saved['notes']);
      expect(
        st.take(5).every((s) => s.bold && s.color == richColors.first),
        isTrue,
      );
      expect(st[6].isPlain, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
