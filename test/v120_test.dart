import 'dart:convert';
import 'dart:io';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/main.dart';
import 'package:project_reminders/mail_intake.dart';
import 'package:project_reminders/shopping.dart';
import 'package:project_reminders/shopping_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'v050_test.dart' show FakeSource;
import 'widget_test.dart' show WidgetRepository;

String b64(String s) => '=?UTF-8?B?${base64.encode(utf8.encode(s))}?=';

String shoppingLetter(String subject, String body, {String id = 'shop-1'}) =>
    'From: Me <me@example.ru>\r\n'
    'To: zadachi@mail.ru\r\n'
    'Subject: ${b64(subject)}\r\n'
    'Date: Fri, 23 Oct 2026 09:00:00 +0300\r\n'
    'Message-ID: <$id@example.ru>\r\n'
    'MIME-Version: 1.0\r\n'
    'Content-Type: text/plain; charset=utf-8\r\n'
    'Content-Transfer-Encoding: base64\r\n'
    '\r\n'
    '${base64.encode(utf8.encode(body))}\r\n';

IncomingMail letter(
  int uid,
  String subject,
  String body, {
  String id = 'shop-1',
}) => IncomingMail(
  uid,
  MimeMessage.parseFromText(shoppingLetter(subject, body, id: id)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Покупки: данные и разбор', () {
    test('Тема письма', () {
      expect(isShoppingSubject('СПИСОК ПОКУПОК'), isTrue);
      expect(isShoppingSubject('Fwd: список покупок'), isTrue);
      expect(isShoppingSubject('Пересл.: Список  покупок: Ашан'), isTrue);
      expect(isShoppingSubject('Покупки на неделю'), isFalse);
      expect(shopHint('СПИСОК ПОКУПОК: Ашан'), 'Ашан');
      expect(shopHint('Список покупок — Лента'), 'Лента');
      expect(shopHint('СПИСОК ПОКУПОК'), isNull);
    });
    test('Строки письма → покупки с количеством', () {
      final items = parseShoppingText('''
-------- Пересылаемое сообщение --------
23.10.2026, 9:00, Жена <wife@example.ru>:
От: Жена
Тема: СПИСОК ПОКУПОК

1. Молоко - 2 л
- Хлеб
• Яйца 10 шт
[ ] Сыр 300 г
* Яблоки x3
молоко

--
Отправлено с iPhone
''');
      expect(items.map((i) => i.text), [
        'Молоко',
        'Хлеб',
        'Яйца',
        'Сыр',
        'Яблоки',
      ]);
      expect(items.map((i) => i.qty), ['2 л', null, '10 шт', '300 г', '3 шт']);
      expect(parseShoppingText('Молоко, хлеб; масло').map((i) => i.text), [
        'Молоко',
        'хлеб',
        'масло',
      ]);
      expect(parseShoppingText('Вода 5').single.qty, '5');
    });
    test('Объединение без повторов и справочник покупок', () {
      final list = {
        'items': [newItem('Молоко'), newItem('Хлеб', qty: '1')],
      };
      final merged = mergeItems(list, [
        newItem('молоко', qty: '2 л'),
        newItem('Сыр'),
      ]);
      final items = merged['items'] as List;
      expect(items.map((i) => i['text']), ['Молоко', 'Хлеб', 'Сыр']);
      expect(items.first['qty'], '2 л');
      final d = Dataset();
      rememberProducts(d, ['Молоко', ' молоко ', 'Хлеб'], 'A');
      rememberProducts(d, ['ХЛЕБ', 'Сыр'], 'A');
      expect(d.visible('product').map((p) => p['name']).toSet(), {
        'Молоко',
        'Хлеб',
        'Сыр',
      });
      final shop = ensureShop(d, 'Пятёрочка', 'A');
      expect(ensureShop(d, ' пятёрочка', 'A'), shop);
      d.write('purchase_list', {
        'id': 'l1',
        'date': '2026-10-23',
        'shopId': shop,
        'items': [newItem('Сыр')],
      }, 'A');
      d.write('purchase_list', {
        'id': 'l2',
        'date': '2026-10-24',
        'shopId': shop,
        'items': [newItem('Сыр'), newItem('Хлеб')],
      }, 'A');
      expect(productNames(d), ['Сыр', 'Хлеб', 'Молоко']); // by frequency
    });
    test('Проверка списка покупок', () {
      Dataset.validateData('purchase_list', {
        'id': 'l',
        'date': '2026-10-23',
        'shopId': 's',
        'items': [newItem('Молоко')],
      });
      Dataset.validateData('purchase_list', {
        'id': 'm',
        'inbox': true,
        'date': null,
        'shopId': null,
        'items': [],
      });
      for (final bad in [
        {'id': 'l', 'date': null, 'shopId': 's', 'items': []},
        {'id': 'l', 'date': '23.10.2026', 'shopId': 's', 'items': []},
        {'id': 'l', 'date': '2026-10-23', 'shopId': null, 'items': []},
        {
          'id': 'l',
          'date': '2026-10-23',
          'shopId': 's',
          'items': [
            {'id': 'a', 'text': ' ', 'done': false},
          ],
        },
        {
          'id': 'l',
          'date': '2026-10-23',
          'shopId': 's',
          'items': [
            newItem('a'),
            {...newItem('b'), 'done': 'нет'},
          ],
        },
      ]) {
        expect(
          () => Dataset.validateData('purchase_list', bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
      Dataset.validateData('shop', {'id': 's', 'name': 'Ашан'});
      expect(
        () => Dataset.validateData('product', {'id': 'p', 'name': ''}),
        throwsFormatException,
      );
    });
  });

  group('Покупки: контроллер', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v120_');
      SharedPreferences.setMockInitialValues({
        'intake_enabled': true,
        'intake_user': 'zadachi@mail.ru',
        'intake_senders': 'me@example.ru',
      });
      FlutterSecureStorage.setMockInitialValues({'intake_password': 'app'});
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
      'Письмо «СПИСОК ПОКУПОК» → предложение, не задача; без дублей',
      () async {
        final box = FakeSource([
          letter(1, 'Fwd: СПИСОК ПОКУПОК: Ашан', 'Молоко 2 л\nХлеб'),
        ]);
        c.mailSource = (_) => box;
        await c.load();
        await c.checkMail();
        expect(c.data.visible('task'), isEmpty);
        final inbox = shoppingInbox(c.data);
        expect(inbox, hasLength(1));
        expect((inbox.single['items'] as List).map((i) => i['text']), [
          'Молоко',
          'Хлеб',
        ]);
        expect(inbox.single['source']['shopHint'], 'Ашан');
        expect(box.processed, [1]);
        expect(c.message, contains('списков покупок: 1'));
        box.processed.clear();
        await c.checkMail();
        expect(shoppingInbox(c.data), hasLength(1));
      },
    );

    test('Принятие письма: добавляется в список даты и магазина', () async {
      await c.load();
      final shop = (await c.addShop('Ашан'))!;
      await c.savePurchaseList({
        'id': 'l1',
        'date': '2026-10-24',
        'shopId': shop,
        'items': [newItem('Хлеб', qty: '1')],
      });
      final inbox = {
        'id': 'shopmail-x',
        'inbox': true,
        'date': null,
        'shopId': null,
        'items': [newItem('хлеб'), newItem('Масло', qty: '1 пач')],
      };
      await c.save('purchase_list', inbox);
      expect(
        await c.acceptShoppingMail(
          inbox,
          date: '2026-10-24',
          shopId: shop,
          items: (inbox['items'] as List).cast<Json>(),
        ),
        isTrue,
      );
      expect(shoppingInbox(c.data), isEmpty);
      final lists = purchaseLists(c.data);
      expect(lists, hasLength(1));
      expect((lists.single['items'] as List).cast<Json>().map(itemLabel), [
        'Хлеб — 1',
        'Масло — 1 пач',
      ]);
      expect(c.data.visible('product').map((p) => p['name']).toSet(), {
        'Хлеб',
        'Масло',
      });
    });

    test(
      'Сохранение второго списка на ту же дату и магазин объединяет их',
      () async {
        await c.load();
        final shop = (await c.addShop('Лента'))!;
        await c.savePurchaseList({
          'id': 'a',
          'date': '2026-10-24',
          'shopId': shop,
          'items': [newItem('Чай')],
        });
        await c.savePurchaseList({
          'id': 'b',
          'date': '2026-10-24',
          'shopId': shop,
          'items': [newItem('Кофе')],
        });
        final lists = purchaseLists(c.data);
        expect(lists.single['id'], 'a');
        expect((lists.single['items'] as List).map((i) => i['text']), [
          'Чай',
          'Кофе',
        ]);
      },
    );
  });

  group('Покупки: интерфейс', () {
    late Directory dir;
    late AppController c;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ui120_');
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

    testWidgets('Новый список: магазин, покупки, отметка и подсказки', (
      tester,
    ) async {
      size(tester, const Size(380, 900));
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Покупки').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Списков покупок пока нет'), findsOneWidget);
      await tester.tap(find.text('Список'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Новый магазин'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Название'),
        'Пятёрочка',
      );
      await tester.tap(find.text('Добавить'));
      await settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Новая покупка'),
        'Молоко',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Кол-во'), '2 л');
      await tester.tap(find.byTooltip('Добавить покупку'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Новая покупка'),
        'Хлеб',
      ); // added on save
      await tester.tap(find.text('Сохранить'));
      await settle(tester);
      expect(find.textContaining('Сегодня, '), findsOneWidget);
      expect(find.text('Пятёрочка'), findsOneWidget);
      expect(find.text('Молоко — 2 л'), findsOneWidget);
      await tester.tap(find.text('Молоко — 2 л'));
      await settle(tester);
      expect(find.text('Куплено 1 из 2'), findsOneWidget);
      // Second list: saved names are suggested.
      await tester.tap(find.text('Список'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Новая покупка'),
        'мол',
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Молоко'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Молоко'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выбрать из сохранённых'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(CheckboxListTile, 'Хлеб'), findsOneWidget);
      expect(
        find.widgetWithText(CheckboxListTile, 'Молоко'),
        findsNothing,
      ); // already in list
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Хлеб'));
      await tester.tap(find.text('Добавить').last);
      await tester.pumpAndSettle();
      expect(find.text('Покупки: 0 из 2 куплено'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Разбор письма: дата, магазин из темы, выбор покупок', (
      tester,
    ) async {
      size(tester, const Size(380, 1000));
      await tester.runAsync(() async {
        await c.save('purchase_list', {
          'id': 'shopmail-1',
          'inbox': true,
          'date': null,
          'shopId': null,
          'items': [
            newItem('Молоко', qty: '2 л'),
            newItem('Хлеб'),
            newItem('Торт'),
          ],
          'source': {
            'from': 'Жена <w@example.ru>',
            'subject': 'СПИСОК ПОКУПОК: Ашан',
            'shopHint': 'Ашан',
          },
        });
      });
      await tester.pumpWidget(TaskApplication(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Покупки').last);
      await tester.pumpAndSettle();
      expect(find.text('Из почты: список покупок (3)'), findsOneWidget);
      await tester.tap(find.text('Разобрать'));
      await tester.pumpAndSettle();
      expect(find.textContaining('магазин «Ашан»'), findsOneWidget);
      await tester.tap(find.text('Добавить в список'));
      await tester.pumpAndSettle();
      expect(find.text('Выберите магазин'), findsOneWidget);
      await tester.tap(find.byTooltip('Новый магазин'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Название'))
            .controller!
            .text,
        'Ашан',
      );
      await tester.tap(find.text('Добавить'));
      await settle(tester);
      await tester.tap(find.text('Торт'));
      await tester.pump();
      expect(find.text('Покупки: 2 из 3'), findsOneWidget);
      await tester.tap(find.text('Добавить в список'));
      await settle(tester);
      expect(find.text('Из почты: список покупок (3)'), findsNothing);
      final list = purchaseLists(c.data).single;
      expect(list['date'], dateKey(DateTime.now()));
      expect((list['items'] as List).map((i) => i['text']), ['Молоко', 'Хлеб']);
      expect(find.text('Ашан'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Справочники покупок и магазинов', (tester) async {
      size(tester, const Size(380, 800));
      await tester.runAsync(() async {
        final shop = (await c.addShop('Лента'))!;
        await c.savePurchaseList({
          'id': 'a',
          'date': '2026-10-24',
          'shopId': shop,
          'items': [newItem('Чай')],
        });
        await c.addShop('Магнит');
      });
      await tester.pumpWidget(
        MaterialApp(home: ShoppingCatalogPage(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Чай'), findsOneWidget);
      await tester.tap(find.text('Магазины'));
      await tester.pumpAndSettle();
      expect(find.text('Лента'), findsOneWidget);
      await tester.tap(
        find.byTooltip('Удалить из справочника').first,
      ); // Лента is used
      await tester.pumpAndSettle();
      expect(find.textContaining('используется в списках'), findsOneWidget);
      await tester.tap(find.byTooltip('Удалить из справочника').last); // Магнит
      await settle(tester);
      expect(find.text('Магнит'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
