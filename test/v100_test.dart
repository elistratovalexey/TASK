import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/export.dart';
import 'package:project_reminders/export_ui.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/planner.dart';
import 'package:project_reminders/planner_ui.dart';
import 'package:project_reminders/storage.dart';
import 'package:project_reminders/updates.dart';
import 'package:project_reminders/version.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'domain_test.dart' show task;
import 'v030_test.dart' show MemoryStore, TestController;
import 'widget_test.dart' show WidgetRepository;

/// Thursday 22.10.2026 10:07 local time.
final now = DateTime(2026, 10, 22, 10, 7);
String iso(DateTime local) => local.toUtc().toIso8601String();

Json t(String id, int estimate, {DateTime? due, int priority = 1}) => {
  ...task(id: id),
  'title': 'Задача $id',
  'estimate': estimate,
  'priority': priority,
  'due': due == null ? null : iso(due),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Версия в коде совпадает с pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $appVersion+'));
    expect(pubspec, contains('msix_version: $appVersion.0'));
    expect(compareVersions('1.0.1', '1.0.0'), greaterThan(0));
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('0.9.12', '1.0.0'), lessThan(0));
    expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
  });

  group('Оценка и рабочее время', () {
    test('Оценка: по умолчанию 1 час, 1 день = 8 часов', () {
      expect(estimateOf(task()), 60);
      expect(estimateLabel(60), '1 ч');
      expect(estimateLabel(8 * 60 + 90), '1 дн. 1 ч 30 мин');
      expect(estimateLabel(45), '45 мин');
      Dataset.validateData('task', {...task(), 'estimate': 90});
      expect(
        () => Dataset.validateData('task', {...task(), 'estimate': -5}),
        throwsFormatException,
      );
      expect(
        () => Dataset.validateData('task', {...task(), 'estimate': 1.5}),
        throwsFormatException,
      );
    });
    test('Рабочий день с перерывом: 8 часов, выходные пустые', () {
      const ws = WorkSchedule();
      expect(ws.capacity(DateTime(2026, 10, 22)), 480);
      expect(ws.capacity(DateTime(2026, 10, 24)), 0);
      expect(
        ws
            .intervals(DateTime(2026, 10, 22))
            .map((i) => '${i.from.hour}-${i.to.hour}'),
        ['9-13', '14-18'],
      );
      expect(const WorkSchedule(days: {}).problem, isNotNull);
      expect(const WorkSchedule(start: 600, end: 540).problem, isNotNull);
      expect(
        const WorkSchedule(breakStart: 480, breakEnd: 540).problem,
        isNotNull,
      );
    });
    test('Настройки рабочего времени сохраняются', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      expect(
        await const WorkSchedule(
          days: {1, 2, 3, 4, 5, 6},
          start: 480,
          end: 1020,
          hasBreak: false,
        ).save(p),
        isTrue,
      );
      final w = WorkSchedule.fromPrefs(p);
      expect(w.days, {1, 2, 3, 4, 5, 6});
      expect(w.capacity(DateTime(2026, 10, 24)), 540);
    });
  });

  group('Планирование', () {
    late Plan plan;
    setUp(() {
      plan = buildPlan(
        [
          t('D', 8 * 60),
          t('B', 120, priority: 2),
          t('C', 360, due: DateTime(2026, 10, 23, 18)),
          t('A', 180, due: DateTime(2026, 10, 22, 12)),
        ],
        const WorkSchedule(),
        now,
      );
    });
    test('Сначала ближайшие сроки, перерыв и выходные пропускаются', () {
      expect(plan.items.map((i) => i.task['id']), ['A', 'C', 'B', 'D']);
      final a = plan.items[0];
      expect(a.slots.first.from, DateTime(2026, 10, 22, 10, 15));
      expect(a.slots.first.to, DateTime(2026, 10, 22, 13));
      expect(a.finish, DateTime(2026, 10, 22, 14, 15));
      expect(plan.items[1].finish, DateTime(2026, 10, 23, 11, 15));
      expect(plan.items[2].finish, DateTime(2026, 10, 23, 14, 15));
      // D: Fri 14:15–18:00, Mon 9–13 and 14–14:15 (weekend skipped).
      expect(plan.items[3].finish, DateTime(2026, 10, 26, 14, 15));
      expect(plan.load(DateTime(2026, 10, 24)), 0);
      expect(plan.load(DateTime(2026, 10, 23)), 480);
      expect(plan.load(DateTime(2026, 10, 22)), 405);
    });
    test('Предложение переноса только для неуспевающей задачи', () {
      expect(plan.suggestions, hasLength(1));
      final s = plan.suggestions.single;
      expect(s.task['id'], 'A');
      expect(s.newDue, DateTime(2026, 10, 22, 14, 15));
    });
    test('Перенос срока сдвигает напоминание и пишет историю', () {
      final a = {
        ...t('A', 60, due: DateTime(2026, 10, 22, 12)),
        'reminder': iso(DateTime(2026, 10, 22, 11)),
      };
      final moved = moveDue(a, DateTime(2026, 10, 23, 12), reason: 'План');
      expect(
        DateTime.parse(moved['due']).toLocal(),
        DateTime(2026, 10, 23, 12),
      );
      expect(
        DateTime.parse(moved['reminder']).toLocal(),
        DateTime(2026, 10, 23, 11),
      );
      final h = (moved['dueHistory'] as List).last;
      expect(h['reason'], 'План');
      Dataset.validateData('task', moved);
    });
    test('Выполненные и неразобранные из почты не планируются', () {
      final d = Dataset()
        ..write('project', {'id': 'p', 'name': 'П'}, 'A')
        ..write('task', t('x', 60), 'A')
        ..write('task', {...t('y', 60), 'done': true}, 'A')
        ..write('task', {...t('z', 60), 'projectId': null, 'inbox': true}, 'A');
      expect(plannable(d).map((e) => e['id']), ['x']);
    });
  });

  group('Excel', () {
    late Dataset d;
    setUp(() {
      d = Dataset()
        ..write('project', {'id': 'p', 'name': 'Сварка'}, 'A')
        ..write('project', {
          'id': 'p2',
          'name': 'Ячейка 1',
          'parentId': 'p',
        }, 'A')
        ..write('project', {'id': 'q', 'name': 'Закупки'}, 'A')
        ..write('task', {
          ...t('a', 90, due: DateTime(2026, 10, 20, 12)),
          'title': 'Проверить "горелку" & сопло <M8>',
          'notes': 'Строка 1\nСтрока 2',
          'color': 'red',
          'startedAt': iso(DateTime(2026, 10, 20, 9)),
          'checklist': [
            {'id': '1', 'text': 'Сопло', 'done': true},
            {'id': '2', 'text': 'Токоподвод', 'done': false},
          ],
        }, 'A')
        ..write('task', {...t('b', 60), 'projectId': 'p2', 'done': true}, 'A')
        ..write('task', {...t('c', 60), 'projectId': 'q'}, 'A')
        ..write('task', {...t('m', 60), 'projectId': null, 'inbox': true}, 'A');
    });
    test('Фильтр по проектам (с подпроектами) и статусам', () {
      List<String> ids(Set<String>? p, Set<String> s) => exportRows(
        d,
        projects: p,
        statuses: s,
        now: now,
      ).map((r) => (r[0] as TextCell).value).toList();
      expect(ids(null, {'active', 'done', 'inbox'}).toSet(), {
        'a',
        'b',
        'c',
        'm',
      });
      expect(ids({'p', 'p2'}, {'active', 'done'}).toSet(), {'a', 'b'});
      expect(ids({'p', 'p2'}, {'done'}), ['b']);
      expect(ids({'q'}, {'active'}), ['c']);
      expect(ids({'q'}, {'inbox'}), ['m']);
      final row = exportRows(
        d,
        projects: {'p'},
        statuses: {'active'},
        now: now,
      ).single;
      expect(row, hasLength(exportHeaders.length));
      expect((row[5] as TextCell).value, 'Да'); // overdue
      expect((row[10] as NumberCell).value, 1.5);
      expect((row[18] as NumberCell).value, 1);
    });
    test('Файл .xlsx: правильная структура и экранирование', () {
      final bytes = buildXlsx(exportHeaders, exportRows(d, now: now));
      final zip = ZipDecoder().decodeBytes(bytes);
      expect(
        zip.files.map((f) => f.name).toSet(),
        containsAll([
          '[Content_Types].xml',
          '_rels/.rels',
          'xl/workbook.xml',
          'xl/styles.xml',
          'xl/worksheets/sheet1.xml',
        ]),
      );
      final sheet = utf8.decode(
        zip.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
      );
      expect(
        sheet,
        contains('Проверить &quot;горелку&quot; &amp; сопло &lt;M8&gt;'),
      );
      expect(sheet, contains('autoFilter ref="A1:AA5"'));
      File(
        '${Directory.systemTemp.path}/v100_check.xlsx',
      ).writeAsBytesSync(bytes);
    });
    test('Дата Excel', () {
      expect(excelDate(DateTime(1900, 1, 1)), 2);
      expect(excelDate(DateTime(2026, 10, 22, 12)), closeTo(46317.5, 1e-9));
    });
    test('Письмо с вложением xlsx', () {
      final m = buildExportMessage(
        from: 'zadachi@mail.ru',
        to: 'boss@example.ru',
        subject: 'Задачи',
        text: 'Выгрузка',
        fileName: 'Задачи_2026-10-22.xlsx',
        file: buildXlsx(exportHeaders, exportRows(d, now: now)),
      );
      expect(m.raw.split('\r\n').every((l) => l.length <= 100), isTrue);
      expect(m.raw.runes.every((r) => r < 128), isTrue);
      final parsed = MimeMessage.parseFromText(m.raw);
      expect(parsed.decodeSubject(), 'Задачи');
      final files = parsed.findContentInfo(
        disposition: ContentDisposition.attachment,
      );
      expect(files.single.fileName, 'Задачи_2026-10-22.xlsx');
      expect(files.single.mediaType?.text, xlsxMime);
    });
  });

  group('Контроллер: отправка, план, обновления', () {
    late Directory dir;
    late TestController c;
    late MemoryStore cloud;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v100_');
      SharedPreferences.setMockInitialValues({
        'provider': 'mail',
        'auto_sync': false,
        'intake_user': 'zadachi@mail.ru',
      });
      FlutterSecureStorage.setMockInitialValues({'intake_password': 'app'});
      cloud = MemoryStore();
      c = TestController(
        Repository(Directory('${dir.path}/a')),
        await SharedPreferences.getInstance(),
        cloud,
      );
      await c.load();
      await c.save('project', {'id': 'p', 'name': 'Сварка'});
      await c.save(
        'task',
        t('a', 600, due: DateTime.now().add(const Duration(hours: 1))),
      );
    });
    tearDown(() async {
      c.dispose();
      await dir.delete(recursive: true);
    });

    test('Отправка Excel: SMTP берётся из ящика «Задачи из почты»', () async {
      SmtpSettings? used;
      ExportMail? sent;
      c.mailSender = (s, m) async {
        used = s;
        sent = m;
      };
      expect(
        await c.sendExport(to: 'boss@example.ru', statuses: {'active'}),
        isTrue,
      );
      expect(used!.host, 'smtp.mail.ru');
      expect(used!.port, 465);
      expect(used!.user, 'zadachi@mail.ru');
      expect(used!.password, 'app');
      expect(sent!.to, 'boss@example.ru');
      expect(
        MimeMessage.parseFromText(
          sent!.raw,
        ).findContentInfo(disposition: ContentDisposition.attachment),
        hasLength(1),
      );
      expect(c.message, contains('отправлен'));
      expect(await c.sendExport(to: 'плохой', statuses: {'active'}), isFalse);
      expect(
        await c.sendExport(to: 'boss@example.ru', statuses: {'done'}),
        isFalse,
      );
      expect(c.message, contains('Нет задач'));
    });

    test('Перенос сроков по предложениям планирования', () async {
      final plan = c.plan();
      expect(plan.suggestions, hasLength(1));
      expect(await c.applySuggestions(plan.suggestions), isTrue);
      final moved = c.data.visible('task').single;
      expect(
        DateTime.parse(moved['due']).toLocal(),
        plan.suggestions.single.newDue,
      );
      expect(
        (moved['dueHistory'] as List).last['reason'],
        contains('Планирование'),
      );
      expect(c.plan().suggestions, isEmpty);
    });

    test('Публикация и проверка обновления', () async {
      expect(await c.checkUpdate(), isNull);
      final apk = File('${dir.path}/app-release.apk')
        ..writeAsBytesSync(List.generate(5000, (i) => i % 251));
      final msix = File('${dir.path}/project_reminders.msix')
        ..writeAsBytesSync([1, 2, 3]);
      await c.publishUpdate(apk: apk, version: '99.0.1', notes: 'Исправления');
      await c.publishUpdate(msix: msix, version: '99.0.1');
      final m = (await c.checkUpdate())!;
      expect(m.version, '99.0.1');
      expect(m.newer, isTrue);
      expect(m.files.keys.toSet(), {'android', 'windows'}); // both kept
      final f = await c.downloadUpdate(m);
      expect(
        await f.readAsBytes(),
        await (Platform.isWindows ? msix : apk).readAsBytes(),
      );
      // Corrupted blob in the cloud is rejected.
      cloud.blobs[m.files[platformKey]!['sha256']] = [9, 9, 9];
      await expectLater(c.downloadUpdate(m), throwsStateError);
      await expectLater(
        c.publishUpdate(apk: apk, version: '1.1'),
        throwsStateError,
      );
    });

    test('Версия из MSIX', () {
      final a = Archive();
      final xml = utf8.encode(
        '<Package><Identity Name="x" Version="1.2.3.0" Publisher="CN=x"/></Package>',
      );
      a.addFile(ArchiveFile('AppxManifest.xml', xml.length, xml));
      expect(msixVersion(ZipEncoder().encodeBytes(a)), '1.2.3');
      expect(msixVersion([1, 2, 3]), isNull);
      expect(
        () => UpdateManifest.parse('{"version":"x","files":{}}'),
        throwsFormatException,
      );
    });
  });

  group('Интерфейс 1.0.0', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ui100_');
      SharedPreferences.setMockInitialValues({});
      c = AppController(
        WidgetRepository(dir),
        await SharedPreferences.getInstance(),
        notifications: false,
      );
      await c.load();
      await c.save('project', {'id': 'p', 'name': 'Сварка'});
      await c.save('task', t('A', 180, due: DateTime(2026, 10, 22, 12)));
      await c.save('task', t('B', 120));
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

    testWidgets('Узкий экран: кнопки календаря, планирования и меню', (
      tester,
    ) async {
      size(tester, const Size(360, 800));
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Календарь занятости'), findsOneWidget);
      expect(find.byTooltip('Планирование'), findsOneWidget);
      expect(find.textContaining('Оценка: 3 ч'), findsOneWidget);
      await tester.tap(find.byTooltip('Ещё'));
      await tester.pumpAndSettle();
      expect(find.text('Задачи в Excel на почту'), findsOneWidget);
      expect(find.text('Проверить обновление'), findsOneWidget);
      await tester.tap(find.text('Задачи в Excel на почту'));
      await tester.pumpAndSettle();
      expect(find.text('Задач в файле: 2'), findsOneWidget);
      await tester.tap(find.text('Выполненные').last);
      await tester.tap(find.text('Активные').last);
      await tester.pumpAndSettle();
      expect(find.text('Задач в файле: 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Календарь занятости и планирование с переносом', (
      tester,
    ) async {
      size(tester, const Size(400, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Column(
              children: [
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (_) => CalendarDialog(controller: c, now: now),
                  ),
                  child: const Text('cal'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute(
                      builder: (_) => PlanningPage(controller: c, now: now),
                    ),
                  ),
                  child: const Text('plan'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('cal'));
      await tester.pumpAndSettle();
      expect(find.text('Октябрь 2026'), findsOneWidget);
      expect(find.textContaining('занято 5 ч из 8 ч'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('day-2026-10-24')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Выходной'), findsWidgets);
      await tester.tap(find.text('Закрыть').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('plan'));
      await tester.pumpAndSettle();
      expect(find.text('Предложения по переносу сроков'), findsOneWidget);
      expect(find.textContaining('→ 22.10.2026 14:15'), findsOneWidget);
      await tester.tap(find.text('Перенести все'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Предложения по переносу сроков'), findsNothing);
      final a = c.data.visible('task').firstWhere((x) => x['id'] == 'A');
      expect(
        DateTime.parse(a['due']).toLocal(),
        DateTime(2026, 10, 22, 14, 15),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Редактор: оценка по умолчанию 1 час и изменение', (
      tester,
    ) async {
      size(tester, const Size(1000, 2200));
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
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Предполагаемое время на выполнение'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Часов'))
            .controller!
            .text,
        '1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Название задачи'),
        'Новая',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Дней'), '1');
      await tester.enterText(find.widgetWithText(TextField, 'Часов'), '2');
      await tester.enterText(find.widgetWithText(TextField, 'Минут'), '30');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(saved!['estimate'], 8 * 60 + 150);
    });

    testWidgets('Все новые экраны на узком экране без ошибок вёрстки', (
      tester,
    ) async {
      size(tester, const Size(360, 740));
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byType(Scaffold).first);
      Future<void> step(void Function() open) async {
        open();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Navigator.of(ctx).pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await step(
        () => showDialog<void>(
          context: ctx,
          builder: (_) => CalendarDialog(controller: c, now: now),
        ),
      );
      await step(
        () => Navigator.of(ctx).push(
          MaterialPageRoute<void>(
            builder: (_) => PlanningPage(controller: c, now: now),
          ),
        ),
      );
      await step(
        () => showDialog<void>(
          context: ctx,
          builder: (_) => ExportDialog(controller: c),
        ),
      );
      await step(
        () => Navigator.of(ctx).push(
          MaterialPageRoute<void>(builder: (_) => WorkTimePage(controller: c)),
        ),
      );
    });
  });
}
