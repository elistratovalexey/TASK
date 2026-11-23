import 'dart:convert';

import 'package:uuid/uuid.dart';

typedef Json = Map<String, dynamic>;
const uuid = Uuid();
Json clone(Json value) => jsonDecode(jsonEncode(value)) as Json;

// Vector clocks preserve concurrent changes, including deletion vs editing.
// No wall-clock based "last writer wins": device clocks may be wrong.
bool dominates(Json a, Json b) {
  final keys = {...a.keys, ...b.keys};
  return keys.every((k) => (a[k] ?? 0) >= (b[k] ?? 0)) &&
      keys.any((k) => (a[k] ?? 0) > (b[k] ?? 0));
}

String canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonical).join(',')}]';
  return jsonEncode(value);
}

/// Record kinds. 'note' = knowledge base entry (since 0.4.0).
const recordKinds = [
  'project',
  'task',
  'note',
  'person',
  'shop',
  'product',
  'purchase_list',
];

class Dataset {
  final Map<String, List<Json>> records;
  Dataset([Map<String, List<Json>>? records]) : records = records ?? {};
  Dataset copy() => Dataset.decode(encode());
  String encode() => canonical({'version': 2, 'records': records});

  static Dataset decode(String raw) {
    if (utf8.encode(raw).length > 10 * 1024 * 1024) {
      throw const FormatException('Файл больше 10 МБ');
    }
    final value = jsonDecode(raw);
    if (value is! Map || value['version'] != 2 || value['records'] is! Map) {
      throw const FormatException('Нужен файл данных версии 2');
    }
    final result = Dataset();
    final entries = (value['records'] as Map).entries;
    if (entries.length > 10000) {
      throw const FormatException('Слишком много записей');
    }
    for (final entry in entries) {
      if (entry.key is! String ||
          entry.value is! List ||
          (entry.value as List).isEmpty ||
          (entry.value as List).length > 100) {
        throw const FormatException('Повреждён список версий');
      }
      final versions = <Json>[];
      for (final item in entry.value as List) {
        if (item is! Map) throw const FormatException('Повреждена запись');
        final v = Map<String, dynamic>.from(item);
        if (!recordKinds.contains(v['kind']) ||
            v['id'] is! String ||
            entry.key != '${v['kind']}:${v['id']}' ||
            v['deleted'] is! bool ||
            v['editId'] is! String ||
            v['clock'] is! Map ||
            (v['clock'] as Map).isEmpty ||
            v['updatedAt'] is! String ||
            DateTime.tryParse(v['updatedAt']) == null) {
          throw const FormatException('Повреждены метаданные записи');
        }
        for (final c in (v['clock'] as Map).entries) {
          if (c.key is! String || c.value is! int || c.value < 1) {
            throw const FormatException('Повреждена версия устройства');
          }
        }
        if (v['data'] is! Map) throw const FormatException('Нет данных записи');
        validateData(v['kind'], Map<String, dynamic>.from(v['data']));
        if (v['data']['id'] != v['id']) {
          throw const FormatException('Неверный ID');
        }
        versions.add(v);
      }
      result.records[entry.key] = normalize(versions);
    }
    return result;
  }

  static void validateData(String kind, Json d) {
    bool text(String key) =>
        d[key] is String && (d[key] as String).length <= 100000;
    if (!text('id') || (d['id'] as String).isEmpty) {
      throw const FormatException('Отсутствует ID');
    }
    if (kind == 'project') {
      if (!text('name') || (d['name'] as String).trim().isEmpty) {
        throw const FormatException('Нет названия проекта');
      }
      if (d['parentId'] != null &&
          (!text('parentId') || d['parentId'] == d['id'])) {
        throw const FormatException('Некорректный родительский проект');
      }
      return;
    }
    if (kind == 'shop' || kind == 'product') {
      if (!text('name') ||
          (d['name'] as String).trim().isEmpty ||
          (d['name'] as String).length > 200) {
        throw const FormatException('Нет названия');
      }
      return;
    }
    if (kind == 'purchase_list') {
      final inbox = d['inbox'] == true;
      if (d['inbox'] != null && d['inbox'] is! bool) {
        throw const FormatException('Некорректный признак входящих');
      }
      final date = d['date'];
      if (date == null
          ? !inbox
          : (date is! String ||
                !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
                DateTime.tryParse(date) == null)) {
        throw const FormatException('Некорректная дата списка покупок');
      }
      final shop = d['shopId'];
      if (shop == null ? !inbox : (shop is! String || shop.isEmpty)) {
        throw const FormatException('Не выбран магазин');
      }
      final items = d['items'];
      if (items is! List || items.length > 1000) {
        throw const FormatException('Повреждён список покупок');
      }
      final ids = <String>{};
      for (final i in items) {
        if (i is! Map ||
            i['id'] is! String ||
            !ids.add(i['id']) ||
            i['text'] is! String ||
            (i['text'] as String).trim().isEmpty ||
            (i['text'] as String).length > 500 ||
            i['done'] is! bool ||
            (i['qty'] != null &&
                (i['qty'] is! String || (i['qty'] as String).length > 50))) {
          throw const FormatException('Повреждена строка списка покупок');
        }
      }
      if (d['note'] != null &&
          (d['note'] is! String || (d['note'] as String).length > 10000)) {
        throw const FormatException('Некорректная заметка');
      }
      return;
    }
    if (kind == 'person') {
      if (!text('name') ||
          (d['name'] as String).trim().isEmpty ||
          (d['name'] as String).length > 200) {
        throw const FormatException('Нет ФИО');
      }
      if (d['position'] != null &&
          (d['position'] is! String ||
              (d['position'] as String).length > 200)) {
        throw const FormatException('Некорректная должность');
      }
      return;
    }
    if (kind == 'note') {
      if (!text('title') || (d['title'] as String).trim().isEmpty) {
        throw const FormatException('Нет названия записи');
      }
      if (d['text'] != null && !text('text')) {
        throw const FormatException('Повреждён текст записи');
      }
      validateTextFormat(d['textFmt']);
      if (d['parentId'] != null &&
          (!text('parentId') || d['parentId'] == d['id'])) {
        throw const FormatException('Некорректная родительская запись');
      }
      validateAttachments(d['attachments']);
      validateColor(d['color']);
      if (d['checklist'] != null) validateChecklist(d['checklist']);
      validatePeople(d['people']);
      return;
    }
    validateTextFormat(d['notesFmt']);
    // A task received by e-mail waits in the inbox until a project is chosen.
    final inbox = d['inbox'] == true;
    if (d['inbox'] != null && d['inbox'] is! bool) {
      throw const FormatException('Повреждена задача');
    }
    if (!text('title') ||
        (d['title'] as String).trim().isEmpty ||
        !(text('projectId') || (inbox && d['projectId'] == null)) ||
        !text('notes') ||
        d['done'] is! bool ||
        ![0, 1, 2].contains(d['priority']) ||
        !['none', 'daily', 'weekly', 'monthly'].contains(d['repeat']) ||
        d['checklist'] is! List) {
      throw const FormatException('Повреждена задача');
    }
    for (final key in ['due', 'reminder', 'startedAt', 'finishedAt']) {
      if (d[key] != null &&
          (d[key] is! String || DateTime.tryParse(d[key]) == null)) {
        throw FormatException('Некорректная дата: $key');
      }
    }
    if (d['startedAt'] != null &&
        d['finishedAt'] != null &&
        DateTime.parse(
          d['finishedAt'],
        ).isBefore(DateTime.parse(d['startedAt']))) {
      throw const FormatException('Окончание раньше начала выполнения');
    }
    if (d['repeat'] != 'none' && d['due'] == null) {
      throw const FormatException('Для повторения нужен срок');
    }
    if (d['repeatDay'] != null &&
        (d['repeatDay'] is! int || d['repeatDay'] < 1 || d['repeatDay'] > 31)) {
      throw const FormatException('Некорректный день повторения');
    }
    validateAttachments(d['attachments']);
    validateDueHistory(d['dueHistory']);
    validateColor(d['color']);
    validatePeople(d['people']);
    if (d['timeline'] != null && d['timeline'] is! bool) {
      throw const FormatException('Некорректный признак шкалы');
    }
    if (d['estimate'] != null &&
        (d['estimate'] is! int ||
            d['estimate'] < 0 ||
            d['estimate'] > 1000 * 8 * 60)) {
      throw const FormatException('Некорректная оценка времени');
    }
    validateChecklist(d['checklist']);
  }

  /// Row colors (since 0.5.0). Unknown keys are rejected.
  static const colorKeys = [
    'red',
    'orange',
    'yellow',
    'green',
    'blue',
    'purple',
    'grey',
  ];
  static void validateColor(dynamic v) {
    if (v != null && !colorKeys.contains(v)) {
      throw const FormatException('Некорректный цвет строки');
    }
  }

  /// Optional list of person IDs involved in a task or note.
  static void validatePeople(dynamic value) {
    if (value == null) return;
    if (value is! List ||
        value.length > 200 ||
        value.any((e) => e is! String || e.isEmpty || e.length > 100) ||
        value.toSet().length != value.length) {
      throw const FormatException('Повреждён список задействованных');
    }
  }

  static void validateChecklist(dynamic list) {
    if (list is! List || list.length > 1000) {
      throw const FormatException('Повреждён чек-лист');
    }
    final ids = <String>{};
    for (final c in list) {
      if (c is! Map ||
          c['id'] is! String ||
          !ids.add(c['id']) ||
          c['text'] is! String ||
          (c['text'] as String).trim().isEmpty ||
          (c['text'] as String).length > 10000 ||
          c['done'] is! bool ||
          (c['color'] != null && !colorKeys.contains(c['color']))) {
        throw const FormatException('Повреждён чек-лист');
      }
    }
  }

  static void validateDueHistory(dynamic list) {
    if (list == null) return;
    if (list is! List || list.length > 1000) {
      throw const FormatException('Повреждена история сроков');
    }
    bool date(dynamic v) =>
        v == null || (v is String && DateTime.tryParse(v) != null);
    for (final h in list) {
      if (h is! Map ||
          h['at'] is! String ||
          DateTime.tryParse(h['at']) == null ||
          !date(h['from']) ||
          !date(h['to']) ||
          (h['reason'] != null &&
              (h['reason'] is! String ||
                  (h['reason'] as String).length > 2000))) {
        throw const FormatException('Повреждена история сроков');
      }
    }
  }

  static const attachmentKinds = ['audio', 'image', 'video', 'file'];
  static void validateAttachments(dynamic list) {
    if (list == null) return;
    if (list is! List || list.length > 200) {
      throw const FormatException('Повреждён список вложений');
    }
    final ids = <String>{};
    for (final a in list) {
      if (a is! Map ||
          a['id'] is! String ||
          !ids.add(a['id']) ||
          a['name'] is! String ||
          (a['name'] as String).isEmpty ||
          (a['name'] as String).length > 255 ||
          a['size'] is! int ||
          a['size'] < 0 ||
          a['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(a['sha256']) ||
          !attachmentKinds.contains(a['kind'])) {
        throw const FormatException('Повреждено вложение');
      }
    }
  }

  static List<Json> normalize(List<Json> versions) {
    final unique = {for (final v in versions) canonical(v): v}.values.toList();
    return unique
        .where(
          (v) => !unique.any(
            (other) => dominates(
              Map<String, dynamic>.from(other['clock']),
              Map<String, dynamic>.from(v['clock']),
            ),
          ),
        )
        .toList()
      ..sort((a, b) => canonical(a).compareTo(canonical(b)));
  }

  Dataset merge(Dataset remote) {
    final out = copy();
    for (final e in remote.records.entries) {
      out.records[e.key] = normalize([...out.records[e.key] ?? [], ...e.value]);
    }
    return out;
  }

  List<String> get conflicts => records.entries
      .where((e) => e.value.length > 1)
      .map((e) => e.key)
      .toList();
  List<Json> visible(String kind) => records.entries
      .where((e) => e.key.startsWith('$kind:'))
      .map((e) => e.value.first)
      .where((v) => v['deleted'] != true)
      .map((v) => clone(v['data'] as Json))
      .toList();
  bool conflicted(String kind, String id) =>
      (records['$kind:$id']?.length ?? 0) > 1;

  void write(String kind, Json data, String device, {bool deleted = false}) {
    validateData(kind, data);
    final key = '$kind:${data['id']}';
    final clock = <String, dynamic>{};
    for (final v in records[key] ?? <Json>[]) {
      for (final e in (v['clock'] as Map).entries) {
        if ((clock[e.key] ?? 0) < e.value) clock[e.key as String] = e.value;
      }
    }
    clock[device] = (clock[device] ?? 0) + 1;
    records[key] = [
      {
        'kind': kind,
        'id': data['id'],
        'data': clone(data),
        'deleted': deleted,
        'clock': clock,
        'editId': uuid.v4(),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      },
    ];
  }

  static Dataset migrate(String raw) {
    final old = jsonDecode(raw);
    if (old is! Map ||
        old['version'] != 1 ||
        old['projects'] is! List ||
        old['tasks'] is! List) {
      throw const FormatException('Не удалось прочитать старые данные');
    }
    final out = Dataset();
    for (final kind in ['project', 'task']) {
      for (final item in old[kind == 'project' ? 'projects' : 'tasks']) {
        final d = Map<String, dynamic>.from(item);
        if (kind == 'task') {
          d.addAll({'reminder': null, 'repeat': 'none', 'checklist': <Json>[]});
        }
        validateData(kind, d);
        final key = '$kind:${d['id']}';
        if (out.records.containsKey(key)) {
          throw const FormatException('Дубликат ID');
        }
        out.records[key] = [
          {
            'kind': kind,
            'id': d['id'],
            'data': d,
            'deleted': false,
            'clock': {'legacy': 1},
            'editId': 'legacy-$key',
            'updatedAt': '2000-01-01T00:00:00.000Z',
          },
        ];
      }
    }
    return out;
  }

  /// Marks a task done (recording the finish time if it was not set) or
  /// reopens it (the finish time is cleared, the start time is kept).
  void complete(Json task, String device, {DateTime? now}) {
    if (task['done'] == true) {
      write('task', {...task, 'done': false, 'finishedAt': null}, device);
      return;
    }
    final moment = now ?? DateTime.now();
    final start = task['startedAt'] == null
        ? null
        : DateTime.parse(task['startedAt']);
    // A start set in the future must not make the finish earlier than it.
    final finished =
        task['finishedAt'] ??
        (start != null && start.isAfter(moment) ? start : moment)
            .toUtc()
            .toIso8601String();
    write('task', {...task, 'done': true, 'finishedAt': finished}, device);
    if (task['repeat'] == 'none' || task['due'] == null) return;
    // Stable successor ID prevents duplicates after offline completion on both devices.
    final nextId = uuid.v5(
      Namespace.url.value,
      'project-reminders/next/${task['id']}',
    );
    if (records.containsKey('task:$nextId')) return;
    final due = DateTime.parse(task['due']).toLocal();
    final next = nextOccurrence(
      due,
      task['repeat'],
      task['repeatDay'] ?? due.day,
    );
    final reminder = task['reminder'] == null
        ? null
        : DateTime.parse(task['reminder']);
    // A planned start/finish set relative to the due time moves with it
    // (Ланч: 10:00–10:30, срок 10:30 → завтра 10:00–10:30).
    final step = next.difference(due);
    String? moved(String? v, {DateTime? notBefore}) {
      if (v == null) return null;
      final d = DateTime.parse(v).toLocal();
      if (d.isAfter(due) || due.difference(d) > step) return null;
      if (notBefore != null && d.isBefore(notBefore)) return null;
      return d.add(step).toUtc().toIso8601String();
    }

    final plannedStart = task['startedAt'] == null
        ? null
        : DateTime.parse(task['startedAt']).toLocal();
    final nextStart = moved(task['startedAt']);
    final nextFinish = nextStart == null
        ? null
        : moved(task['finishedAt'], notBefore: plannedStart);
    write('task', {
      ...clone(task),
      'id': nextId,
      'done': false,
      'due': next.toUtc().toIso8601String(),
      'repeatDay': task['repeatDay'] ?? due.day,
      'reminder': reminder == null
          ? null
          : next.subtract(due.difference(reminder)).toUtc().toIso8601String(),
      'checklist': [
        for (final c in task['checklist']) {...c as Map, 'done': false},
      ],
      'dueHistory': <Json>[],
      'startedAt': nextStart,
      'finishedAt': nextFinish,
    }, device);
  }
}

/// Formatting of a text field (see rich_text.dart): null or
/// {'v': 1, 'md5': String, 'runs': [{'s': int, 'e': int, ...}]}.
void validateTextFormat(Object? f) {
  if (f == null) return;
  if (f is! Map || f['md5'] is! String || f['runs'] is! List) {
    throw const FormatException('Повреждено форматирование текста');
  }
  for (final r in f['runs'] as List) {
    if (r is! Map ||
        r['s'] is! int ||
        r['e'] is! int ||
        (r['s'] as int) < 0 ||
        (r['e'] as int) < (r['s'] as int) ||
        (r['l'] != null &&
            (r['l'] is! String || (r['l'] as String).length > 2000))) {
      throw const FormatException('Повреждено форматирование текста');
    }
  }
}

/// Time spent on a task, or null if start or finish is not set.
Duration? spentTime(Json task) {
  final s = task['startedAt'], f = task['finishedAt'];
  if (s == null || f == null) return null;
  return DateTime.parse(f).difference(DateTime.parse(s));
}

/// "45 мин", "3 ч 20 мин", "2 дн. 4 ч".
String durationLabel(Duration d) {
  if (d.isNegative) return '—';
  final days = d.inDays, hours = d.inHours % 24, minutes = d.inMinutes % 60;
  if (days > 0) return hours > 0 ? '$days дн. $hours ч' : '$days дн.';
  if (hours > 0) return minutes > 0 ? '$hours ч $minutes мин' : '$hours ч';
  return d.inMinutes > 0 ? '${d.inMinutes} мин' : 'меньше минуты';
}

DateTime nextOccurrence(DateTime due, String repeat, int anchorDay) {
  if (repeat == 'daily' || repeat == 'weekly') {
    return DateTime(
      due.year,
      due.month,
      due.day + (repeat == 'daily' ? 1 : 7),
      due.hour,
      due.minute,
    );
  }
  final days = DateTime(due.year, due.month + 2, 0).day;
  return DateTime(
    due.year,
    due.month + 1,
    anchorDay > days ? days : anchorDay,
    due.hour,
    due.minute,
  );
}

/// Project tree. Cycles (possible after concurrent offline edits on two
/// devices) are broken deterministically: such a project is shown as a root.
class ProjectTree {
  final String nameKey;
  final Map<String, Json> byId;
  final Map<String, List<Json>> children = {};
  final List<Json> roots = [];
  ProjectTree(List<Json> projects, {this.nameKey = 'name'})
    : byId = {for (final p in projects) p['id'] as String: p} {
    for (final p in byId.values) {
      final parent = effectiveParent(p['id']);
      if (parent == null) {
        roots.add(p);
      } else {
        children.putIfAbsent(parent, () => []).add(p);
      }
    }
    int byName(Json a, Json b) => (a[nameKey] as String)
        .toLowerCase()
        .compareTo((b[nameKey] as String).toLowerCase());
    roots.sort(byName);
    for (final list in children.values) {
      list.sort(byName);
    }
  }

  /// Parent if it exists and does not lead to a cycle.
  String? effectiveParent(String id) {
    final parent = byId[id]?['parentId'] as String?;
    if (parent == null || !byId.containsKey(parent)) return null;
    final seen = <String>{id};
    String? cur = parent;
    while (cur != null) {
      if (!seen.add(cur)) return null;
      final next = byId[cur]?['parentId'] as String?;
      cur = next != null && byId.containsKey(next) ? next : null;
    }
    return parent;
  }

  /// Depth-first order with nesting level.
  List<({Json project, int depth})> flatten() {
    final out = <({Json project, int depth})>[];
    void walk(Json p, int depth) {
      out.add((project: p, depth: depth));
      for (final c in children[p['id']] ?? const <Json>[]) {
        walk(c, depth + 1);
      }
    }

    for (final r in roots) {
      walk(r, 0);
    }
    return out;
  }

  /// The project itself and all nested subprojects.
  Set<String> subtree(String id) {
    final out = <String>{};
    void walk(String x) {
      if (!out.add(x)) return;
      for (final c in children[x] ?? const <Json>[]) {
        walk(c['id']);
      }
    }

    walk(id);
    return out;
  }

  String path(String id) {
    final names = <String>[];
    String? cur = id;
    final seen = <String>{};
    while (cur != null && byId.containsKey(cur) && seen.add(cur)) {
      names.insert(0, byId[cur]![nameKey]);
      cur = effectiveParent(cur);
    }
    return names.join(' / ');
  }
}

/// Returns the task with an entry appended to its due date history if the
/// due date differs from the previously saved version.
Json withDueHistory(Json? old, Json updated, {String? reason, DateTime? now}) {
  final history = <Json>[
    for (final h in (old?['dueHistory'] as List?) ?? const []) clone(h),
  ];
  final before = old?['due'] as String?;
  final after = updated['due'] as String?;
  bool same(String? a, String? b) =>
      a == b ||
      (a != null &&
          b != null &&
          DateTime.parse(a).isAtSameMomentAs(DateTime.parse(b)));
  if (!same(before, after) && !(old == null && after == null)) {
    final r = reason?.trim() ?? '';
    history.add({
      'at': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'from': before,
      'to': after,
      if (r.isNotEmpty) 'reason': r,
    });
  }
  return {...updated, 'dueHistory': history};
}
