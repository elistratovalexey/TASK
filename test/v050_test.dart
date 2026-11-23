import 'dart:io';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/attachments.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/mail_intake.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'domain_test.dart' show task;
import 'widget_test.dart' show WidgetRepository;

const raw =
    'From: =?UTF-8?B?0JDQu9C10LrRgdC10Lk=?= <boss@example.ru>\r\n'
    'To: zadachi@mail.ru\r\n'
    'Subject: =?UTF-8?B?RndkOiDQodGF0LXQvNCwINGP0YfQtdC50LrQuA==?=\r\n'
    'Date: Wed, 21 Oct 2026 10:15:00 +0300\r\n'
    'Message-ID: <abc-1@example.ru>\r\n'
    'MIME-Version: 1.0\r\n'
    'Content-Type: multipart/mixed; boundary="XX"\r\n'
    '\r\n'
    '--XX\r\n'
    'Content-Type: text/html; charset=utf-8\r\n'
    'Content-Transfer-Encoding: 8bit\r\n'
    '\r\n'
    '<html><body><p>Проверить&nbsp;сварку</p><div>Срок — пятница</div></body></html>\r\n'
    '--XX\r\n'
    'Content-Type: application/pdf; name="drawing.pdf"\r\n'
    'Content-Disposition: attachment; filename="drawing.pdf"\r\n'
    'Content-Transfer-Encoding: base64\r\n'
    '\r\n'
    'JVBERi0xLjQK\r\n'
    '--XX--\r\n';

String letter({String from = 'boss@example.ru', String id = 'abc-1'}) => raw
    .replaceFirst('<boss@example.ru>', '<$from>')
    .replaceFirst('<abc-1@example.ru>', '<$id@example.ru>');

class FakeSource implements MailSource {
  final List<IncomingMail> box;
  final processed = <int>[];
  bool failMove = false;
  FakeSource(this.box);
  @override
  Future<List<IncomingMail>> fetch({int max = 20}) async =>
      box.where((m) => !processed.contains(m.uid)).toList();
  @override
  Future<void> markProcessed(int uid) async {
    if (failMove) throw StateError('MOVE не поддерживается');
    processed.add(uid);
  }

  @override
  Future<void> close() async {}
}

IncomingMail mail(int uid, String text) =>
    IncomingMail(uid, MimeMessage.parseFromText(text));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Данные 0.5.0', () {
    test('Цвет строки и пунктов чек-листа', () {
      Dataset.validateData('task', {
        ...task(),
        'color': 'red',
        'checklist': [
          {'id': 'a', 'text': 'Пункт', 'done': false, 'color': 'green'},
        ],
      });
      expect(
        () => Dataset.validateData('task', {...task(), 'color': 'pink'}),
        throwsFormatException,
      );
      expect(
        () => Dataset.validateData('task', {
          ...task(),
          'checklist': [
            {'id': 'a', 'text': 'x', 'done': false, 'color': '#fff'},
          ],
        }),
        throwsFormatException,
      );
    });
    test('Чек-лист и цвет у записи базы знаний', () {
      Dataset.validateData('note', {
        'id': 'n',
        'title': 'Проверка',
        'color': 'blue',
        'checklist': [
          {'id': 'a', 'text': 'Шаг', 'done': true},
        ],
      });
      expect(
        () => Dataset.validateData('note', {
          'id': 'n',
          'title': 'X',
          'checklist': [
            {'id': 'a', 'text': ' ', 'done': true},
          ],
        }),
        throwsFormatException,
      );
    });
    test('Задача без проекта допустима только во входящих', () {
      Dataset.validateData('task', {
        ...task(),
        'projectId': null,
        'inbox': true,
      });
      expect(
        () => Dataset.validateData('task', {...task(), 'projectId': null}),
        throwsFormatException,
      );
    });
  });

  group('Разбор письма', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('mail_'));
    tearDown(() async => dir.delete(recursive: true));

    test('Тема без Fwd, текст из HTML, вложение PDF', () async {
      final store = AttachmentStore(dir);
      final t = await taskFromMail(
        mail(7, raw),
        store,
        Directory('${dir.path}/tmp'),
      );
      expect(t['title'], 'Схема ячейки');
      expect(t['inbox'], isTrue);
      expect(t['projectId'], isNull);
      expect(t['notes'], contains('Из почты: Алексей <boss@example.ru>'));
      expect(t['notes'], contains('Проверить сварку'));
      expect(t['notes'], contains('Срок — пятница'));
      final a = (t['attachments'] as List).single as Json;
      expect(a['name'], 'drawing.pdf');
      expect(await store.file(a).readAsString(), startsWith('%PDF-1.4'));
      Dataset.validateData('task', t);
    });
    test('Префиксы пересылки и ответа убираются', () {
      expect(cleanSubject('Fwd: RE: Пересл.: Заказ'), 'Заказ');
      expect(cleanSubject('Fw: Re[2]: Отв: Заказ 15'), 'Заказ 15');
      expect(cleanSubject('Пересл: Счёт'), 'Счёт');
    });
    test('Одно письмо — один и тот же ID задачи', () {
      expect(
        mailTaskId(MimeMessage.parseFromText(raw), 1),
        mailTaskId(MimeMessage.parseFromText(raw), 99),
      );
    });
  });

  group('Приём почты в контроллере', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('intake_');
      SharedPreferences.setMockInitialValues({
        'intake_enabled': true,
        'intake_user': 'zadachi@mail.ru',
        'intake_senders': 'Boss@Example.ru, me@example.ru',
      });
      FlutterSecureStorage.setMockInitialValues({
        'intake_password': 'app-pass',
      });
      c = AppController(
        WidgetRepository(dir),
        await SharedPreferences.getInstance(),
        notifications: false,
      );
    });
    tearDown(() async {
      c.dispose();
      await dir.delete(recursive: true);
    });

    test(
      'Задача создаётся, письмо переносится, чужие письма не трогаются',
      () async {
        final box = FakeSource([
          mail(1, letter()),
          mail(2, letter(from: 'spam@evil.com', id: 'spam')),
        ]);
        c.mailSource = (_) => box;
        await c.load(); // load() also checks mail
        await c.checkMail();
        expect(c.mailError, isNull);
        expect(c.inboxTasks, hasLength(1));
        expect(box.processed, [1]);
        expect(c.message, contains('Из почты получено задач: 1'));
      },
    );

    test('Если перенос письма не удался, дубля не будет', () async {
      final box = FakeSource([mail(1, letter())])..failMove = true;
      c.mailSource = (_) => box;
      await c.load();
      await c.checkMail();
      expect(c.mailError, contains('MOVE'));
      box.failMove = false;
      await c.checkMail();
      expect(c.inboxTasks, hasLength(1));
      expect(box.processed, [1]);
    });

    test('Без разрешённых отправителей почта не читается', () async {
      await c.prefs.setString('intake_senders', '');
      var opened = false;
      c.mailSource = (_) {
        opened = true;
        return FakeSource([]);
      };
      await c.load();
      await c.checkMail();
      expect(opened, isFalse);
      expect(c.mailError, contains('разрешённого отправителя'));
    });
  });

  group('Интерфейс 0.5.0', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ui5_');
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

    testWidgets('Разбор задачи из почты: без проекта не сохраняется', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await c.save('project', {'id': 'p', 'name': 'Сварка'});
        await c.save('task', {
          ...task(id: 'm'),
          'title': 'Схема ячейки',
          'projectId': null,
          'inbox': true,
        });
      });
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      expect(find.textContaining('Из почты: 1'), findsOneWidget);
      await tester.tap(find.text('Разобрать'));
      await tester.pumpAndSettle();
      expect(find.text('Задача из почты'), findsOneWidget);
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Выберите проект'), findsOneWidget);
      await tester.tap(find.text('— выберите проект —'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сварка').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Красный'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Красный'));
      await tester.pump();
      await tester.tap(find.text('Сохранить'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final t = c.data.visible('task').single;
      expect(t['inbox'], isNull);
      expect(t['projectId'], 'p');
      expect(t['color'], 'red');
      expect(find.textContaining('Из почты:'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Запись базы знаний с чек-листом и цветом', (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      await tester.enterText(
        find.widgetWithText(TextField, 'Новый пункт'),
        'Проверить газ',
      );
      await tester.tap(find.byTooltip('Добавить пункт'));
      await tester.pump();
      // Typed but not added item is added on save.
      await tester.enterText(
        find.widgetWithText(TextField, 'Новый пункт'),
        'Включить вытяжку',
      );
      await tester.ensureVisible(find.byTooltip('Зелёный'));
      await tester.tap(find.byTooltip('Зелёный'));
      await tester.pump();
      await tester.tap(find.text('Сохранить'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final n = c.data.visible('note').single;
      expect(n['color'], 'green');
      expect((n['checklist'] as List).map((x) => x['text']), [
        'Проверить газ',
        'Включить вытяжку',
      ]);
      expect(find.text('Чек-лист: 0/2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
