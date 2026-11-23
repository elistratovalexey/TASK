import 'package:enough_mail/enough_mail.dart';
import 'package:uuid/uuid.dart';
import 'domain.dart';
import 'mail_intake.dart';

const _uuid = Uuid();

/// Local calendar date as "YYYY-MM-DD".
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime parseDateKey(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

String normalizeText(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');
String _low(String s) => normalizeText(s).toLowerCase();

List<Json> shopsList(Dataset d) =>
    d.visible('shop').toList()
      ..sort((a, b) => _low(a['name']).compareTo(_low(b['name'])));

Map<String, Json> shopsById(Dataset d) => {
  for (final s in d.visible('shop')) s['id'] as String: s,
};

/// Sorted purchase lists (not from the mail inbox).
List<Json> purchaseLists(Dataset d) =>
    d.visible('purchase_list').where((l) => l['inbox'] != true).toList();

List<Json> shoppingInbox(Dataset d) => d
    .visible('purchase_list')
    .where((l) => l['inbox'] == true && !d.conflicted('purchase_list', l['id']))
    .toList();

Json? listFor(Dataset d, String date, String shopId, {String? exceptId}) =>
    purchaseLists(d)
        .where(
          (l) =>
              l['date'] == date && l['shopId'] == shopId && l['id'] != exceptId,
        )
        .firstOrNull;

/// Saved purchase names, most used first, then alphabetically.
List<String> productNames(Dataset d) {
  final freq = <String, int>{};
  for (final l in purchaseLists(d)) {
    for (final i in l['items'] as List) {
      final k = _low(i['text']);
      freq[k] = (freq[k] ?? 0) + 1;
    }
  }
  final names = d.visible('product').map((p) => p['name'] as String).toList()
    ..sort((a, b) {
      final f = (freq[_low(b)] ?? 0).compareTo(freq[_low(a)] ?? 0);
      return f != 0 ? f : _low(a).compareTo(_low(b));
    });
  return names;
}

/// Remembers purchase names that are not yet in the directory.
void rememberProducts(Dataset d, Iterable<String> names, String device) {
  final known = {for (final p in d.visible('product')) _low(p['name'])};
  for (final n in names) {
    final name = normalizeText(n);
    if (name.isEmpty || !known.add(name.toLowerCase())) continue;
    d.write('product', {'id': _uuid.v4(), 'name': name}, device);
  }
}

/// Finds a shop by name or creates it. Returns its ID.
String ensureShop(Dataset d, String name, String device) {
  final n = normalizeText(name);
  final found = d
      .visible('shop')
      .where((s) => _low(s['name']) == n.toLowerCase())
      .firstOrNull;
  if (found != null) return found['id'];
  final id = _uuid.v4();
  d.write('shop', {'id': id, 'name': n}, device);
  return id;
}

Json newItem(String text, {String? qty}) => {
  'id': _uuid.v4(),
  'text': normalizeText(text),
  'done': false,
  if (qty != null && qty.trim().isNotEmpty) 'qty': qty.trim(),
};

/// Adds items to a list; an item already in the list (same name) is not
/// duplicated — its quantity is filled in if it was empty.
Json mergeItems(Json list, Iterable<Json> items) {
  final result = [
    for (final i in list['items'] as List) Map<String, dynamic>.from(i),
  ];
  for (final item in items) {
    final same = result
        .where((i) => _low(i['text']) == _low(item['text']))
        .firstOrNull;
    if (same == null) {
      result.add({...item, 'id': item['id'] ?? _uuid.v4()});
    } else if ((same['qty'] == null || same['qty'] == '') &&
        item['qty'] != null) {
      same['qty'] = item['qty'];
    }
  }
  return {...list, 'items': result};
}

/// Subject "СПИСОК ПОКУПОК" (any case, also after Fwd:/Пересл.:).
bool isShoppingSubject(String? subject) =>
    _low(cleanSubject(subject)).startsWith('список покупок');

/// "Список покупок: Ашан" → "Ашан".
String? shopHint(String? subject) {
  final s = normalizeText(cleanSubject(subject));
  if (!s.toLowerCase().startsWith('список покупок')) return null;
  final rest = s
      .substring('список покупок'.length)
      .replaceFirst(RegExp(r'^[\s:\-–—.,]+'), '')
      .trim();
  return rest.isEmpty ? null : rest;
}

final _qty = RegExp(
  r'^(.*?)[\s,:–—-]+(\d+(?:[.,]\d+)?\s*(?:шт|кг|гр|г|л|мл|уп|упак|пач|бут|банк[аи]?|м|пакет[а-я]*|десят[а-я]*)?\.?)$',
  caseSensitive: false,
);
final _qtyX = RegExp(r'^(.*?)\s*[xх×*]\s*(\d+)$', caseSensitive: false);

/// Splits "Молоко - 2 л" into name and quantity.
({String text, String? qty}) splitQty(String line) {
  for (final re in [_qtyX, _qty]) {
    final m = re.firstMatch(line);
    if (m != null &&
        m[1]!.trim().isNotEmpty &&
        RegExp(r'[A-Za-zА-Яа-яЁё]').hasMatch(m[1]!)) {
      final q = m[2]!.trim();
      return (text: m[1]!.trim(), qty: re == _qtyX ? '$q шт' : q);
    }
  }
  return (text: line, qty: null);
}

/// Purchase lines from the letter text: one per line (or comma separated),
/// bullets, numbers and check boxes removed, quoted/forwarded headers and
/// signatures skipped.
List<({String text, String? qty})> parseShoppingText(String body) {
  final header = RegExp(
    r'^(от|кому|тема|дата|копия|from|to|subject|date|cc|sent|отправлено)\s*:',
    caseSensitive: false,
  );
  final noise = RegExp(
    r'^(-{2,}.*|_{3,}|отправлено (с|из) .*|sent from .*|пересылаемое сообщение.*|forwarded message.*|из почты:.*)$',
    caseSensitive: false,
  );
  final lines = <String>[];
  for (var raw in body.replaceAll('\r', '').split('\n')) {
    var l = raw.trim();
    if (l == '--' || l == '-- ') break; // signature
    if (l.isEmpty ||
        l.startsWith('>') ||
        header.hasMatch(l) ||
        noise.hasMatch(l) ||
        l.contains('@')) {
      continue;
    }
    l = l
        .replaceFirst(
          RegExp(
            r'^(\[[ xх✓✔]?\]|[☐☑✓✔•●▪◦\-–—*+·]|\d{1,3}[.)])\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    if (l.isEmpty) continue;
    lines.add(l);
  }
  final parts = lines.length == 1 && RegExp(r'[,;]').hasMatch(lines.single)
      ? lines.single
            .split(RegExp(r'[,;]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
      : lines;
  final seen = <String>{};
  return [
    for (final p in parts.take(300))
      if (p.length <= 200 && seen.add(_low(splitQty(p).text))) splitQty(p),
  ];
}

/// An inbox purchase list from a "СПИСОК ПОКУПОК" letter.
Json shoppingFromMail(IncomingMail mail) {
  final m = mail.message;
  final text = mail.truncated
      ? ''
      : (m.decodeTextPlainPart() ??
            (m.decodeTextHtmlPart() == null
                ? ''
                : htmlToText(m.decodeTextHtmlPart()!)));
  final from = m.from?.firstOrNull;
  return {
    'id': 'shop${mailTaskId(m, mail.uid)}',
    'inbox': true,
    'date': null,
    'shopId': null,
    'items': [
      for (final i in parseShoppingText(text)) newItem(i.text, qty: i.qty),
    ],
    'source': {
      'from': from == null
          ? ''
          : (from.personalName?.isNotEmpty == true
                ? '${from.personalName} <${from.email}>'
                : from.email),
      'subject': m.decodeSubject() ?? '',
      'date': m.decodeDate()?.toUtc().toIso8601String(),
      if (shopHint(m.decodeSubject()) != null)
        'shopHint': shopHint(m.decodeSubject()),
    },
  };
}

bool isShoppingMail(MimeMessage m) => isShoppingSubject(m.decodeSubject());
