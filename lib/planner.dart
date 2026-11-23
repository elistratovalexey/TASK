import 'package:shared_preferences/shared_preferences.dart';
import 'domain.dart';

/// Default estimate for a task: 1 hour.
const defaultEstimate = 60;

/// In estimates, one day means one standard working day of 8 hours.
const estimateDayMinutes = 8 * 60;

int estimateOf(Json t) {
  final v = t['estimate'];
  return v is int && v > 0 ? v : defaultEstimate;
}

/// "1 ч", "2 дн. 3 ч 15 мин" (days are 8-hour working days).
String estimateLabel(int minutes) {
  final d = minutes ~/ estimateDayMinutes;
  final h = (minutes % estimateDayMinutes) ~/ 60;
  final m = minutes % 60;
  final parts = [if (d > 0) '$d дн.', if (h > 0) '$h ч', if (m > 0) '$m мин'];
  return parts.isEmpty ? '0 мин' : parts.join(' ');
}

String hm(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// Working time of this device's user.
class WorkSchedule {
  final Set<int> days; // DateTime.monday .. DateTime.sunday
  final int start; // minutes from midnight
  final int end;
  final bool hasBreak;
  final int breakStart;
  final int breakEnd;
  const WorkSchedule({
    this.days = const {1, 2, 3, 4, 5},
    this.start = 9 * 60,
    this.end = 18 * 60,
    this.hasBreak = true,
    this.breakStart = 13 * 60,
    this.breakEnd = 14 * 60,
  });

  String? get problem {
    if (days.isEmpty) return 'Не выбран ни один рабочий день';
    if (end <= start) return 'Конец рабочего дня раньше начала';
    if (hasBreak &&
        (breakEnd <= breakStart || breakStart < start || breakEnd > end)) {
      return 'Перерыв должен быть внутри рабочего дня';
    }
    return null;
  }

  factory WorkSchedule.fromPrefs(SharedPreferences p) {
    const d = WorkSchedule();
    final days = (p.getString('work_days') ?? '1,2,3,4,5')
        .split(',')
        .map((e) => int.tryParse(e.trim()))
        .whereType<int>()
        .where((e) => e >= 1 && e <= 7)
        .toSet();
    return WorkSchedule(
      days: days,
      start: p.getInt('work_start') ?? d.start,
      end: p.getInt('work_end') ?? d.end,
      hasBreak: p.getBool('break_on') ?? d.hasBreak,
      breakStart: p.getInt('break_start') ?? d.breakStart,
      breakEnd: p.getInt('break_end') ?? d.breakEnd,
    );
  }

  Future<bool> save(SharedPreferences p) async {
    final results = await Future.wait([
      p.setString('work_days', (days.toList()..sort()).join(',')),
      p.setInt('work_start', start),
      p.setInt('work_end', end),
      p.setBool('break_on', hasBreak),
      p.setInt('break_start', breakStart),
      p.setInt('break_end', breakEnd),
    ]);
    return !results.contains(false);
  }

  /// Working intervals of a local calendar day.
  List<({DateTime from, DateTime to})> intervals(DateTime day) {
    if (!days.contains(day.weekday)) return const [];
    DateTime at(int m) =>
        DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
    if (!hasBreak) return [(from: at(start), to: at(end))];
    return [
      if (breakStart > start) (from: at(start), to: at(breakStart)),
      if (end > breakEnd) (from: at(breakEnd), to: at(end)),
    ];
  }

  int capacity(DateTime day) =>
      intervals(day).fold(0, (s, i) => s + i.to.difference(i.from).inMinutes);
}

class Slot {
  final Json task;
  final DateTime from;
  final DateTime to;
  final int part;
  int parts = 1;
  bool fixed = false;
  Slot(this.task, this.from, this.to, this.part);
  int get minutes => to.difference(from).inMinutes;
}

class PlanItem {
  final Json task;
  final List<Slot> slots;
  final DateTime finish;
  final bool fixed;
  PlanItem(this.task, this.slots, this.finish, {this.fixed = false});
  DateTime? get due =>
      task['due'] == null ? null : DateTime.parse(task['due']).toLocal();
  bool get late => due != null && finish.isAfter(due!);
}

class Suggestion {
  final Json task;
  final DateTime oldDue;
  final DateTime newDue;
  Suggestion(this.task, this.oldDue, this.newDue);
  Duration get shift => newDue.difference(oldDue);
}

class Plan {
  final List<PlanItem> items;
  final Map<DateTime, List<Slot>> byDay;
  final List<Suggestion> suggestions;
  final String? problem;
  final WorkSchedule schedule;
  Plan(this.items, this.byDay, this.suggestions, this.schedule, {this.problem});
  int get totalMinutes => items.fold(0, (s, i) => s + estimateOf(i.task));
  DateTime? get end => items.isEmpty
      ? null
      : items.map((i) => i.finish).reduce((a, b) => a.isAfter(b) ? a : b);
  int load(DateTime day) =>
      (byDay[DateTime(day.year, day.month, day.day)] ?? const <Slot>[]).fold(
        0,
        (s, x) => s + x.minutes,
      );
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Tasks that take part in planning: not done and already sorted out
/// (inbox tasks from e-mail still need a project).
List<Json> plannable(Dataset data) => data
    .visible('task')
    .where((t) => t['done'] != true && t['inbox'] != true && onTimeline(t))
    .toList();

/// The task's "Показывать на временной шкале" check box (on by default).
/// A task without it is not planned and not shown in the calendar.
bool onTimeline(Json t) => t['timeline'] != false;

/// Planned start set in the task ("Начало выполнения"), if any.
/// Done tasks are not planned at all, so an end time does not matter here.
DateTime? fixedStart(Json t) => t['startedAt'] == null || t['done'] == true
    ? null
    : DateTime.parse(t['startedAt']).toLocal();

/// "Рассчитать начало": the due time minus the estimate. Up to one
/// working day (8 h) it is plain clock time; longer estimates are counted
/// back through the working time, the same way the plan lays them out.
DateTime startBeforeDue(DateTime due, int minutes, WorkSchedule ws) {
  if (minutes <= estimateDayMinutes || ws.days.isEmpty) {
    return due.subtract(Duration(minutes: minutes));
  }
  var left = minutes;
  var day = DateTime(due.year, due.month, due.day);
  for (var n = 0; n < 3660; n++) {
    for (final w in ws.intervals(day).reversed) {
      final to = w.to.isAfter(due) ? due : w.to;
      if (!to.isAfter(w.from)) continue;
      final len = to.difference(w.from).inMinutes;
      if (len >= left) return to.subtract(Duration(minutes: left));
      left -= len;
    }
    day = DateTime(day.year, day.month, day.day - 1);
  }
  return due.subtract(Duration(minutes: minutes));
}

/// Builds the plan.
///
/// Tasks with a start time set in the task are fixed: they take exactly
/// [start, start + estimate] (an estimate longer than one working day is
/// spread over working time from the start). They may be outside working
/// hours (personal tasks in the evening or at the weekend).
///
/// The other tasks are placed one after another into the remaining free
/// working time starting from [now]: tasks with a due date first (earliest
/// deadline first — this minimizes lateness), then by priority; tasks
/// without a due date go last.
/// For each task that would finish after its due date a new due date is
/// suggested: the moment the plan expects it to be finished.
Plan buildPlan(List<Json> tasks, WorkSchedule ws, DateTime now) {
  final problem = ws.problem;
  if (problem != null) return Plan([], {}, [], ws, problem: problem);
  final items = <PlanItem>[];
  final byDay = <DateTime, List<Slot>>{};
  final busy = <({DateTime from, DateTime to})>[];

  void add(Json t, List<Slot> slots, {bool fixed = false}) {
    if (slots.isEmpty) return;
    for (final s in slots) {
      s.parts = slots.length;
      s.fixed = fixed;
      byDay.putIfAbsent(_day(s.from), () => []).add(s);
    }
    items.add(PlanItem(t, slots, slots.last.to, fixed: fixed));
  }

  /// Working intervals of [day] minus fixed tasks.
  List<({DateTime from, DateTime to})> free(DateTime day) {
    var parts = [for (final i in ws.intervals(day)) (from: i.from, to: i.to)];
    for (final b in busy) {
      parts = [
        for (final p in parts)
          if (!b.to.isAfter(p.from) || !b.from.isBefore(p.to))
            p
          else ...[
            if (b.from.isAfter(p.from)) (from: p.from, to: b.from),
            if (b.to.isBefore(p.to)) (from: b.to, to: p.to),
          ],
      ];
    }
    return parts;
  }

  /// Fills free working time from [start]; returns the slots.
  List<Slot> fill(Json t, int minutes, DateTime start, {bool useBusy = true}) {
    var left = minutes;
    var cursor = start;
    var day = _day(cursor);
    final horizon = _day(start).add(const Duration(days: 3 * 365));
    final slots = <Slot>[];
    while (left > 0 && !day.isAfter(horizon)) {
      final intervals = useBusy
          ? free(day)
          : [for (final i in ws.intervals(day)) (from: i.from, to: i.to)];
      for (final i in intervals) {
        if (!i.to.isAfter(cursor)) continue;
        final from = cursor.isAfter(i.from) ? cursor : i.from;
        final room = i.to.difference(from).inMinutes;
        if (room <= 0) continue;
        final take = left < room ? left : room;
        final slot = Slot(
          t,
          from,
          from.add(Duration(minutes: take)),
          slots.length + 1,
        );
        slots.add(slot);
        left -= take;
        cursor = slot.to;
        if (left == 0) break;
      }
      if (left > 0) {
        day = day.add(const Duration(days: 1));
        day = DateTime(day.year, day.month, day.day); // DST safe
        if (cursor.isBefore(day)) cursor = day;
      }
    }
    return slots;
  }

  // 1. Fixed tasks.
  final floating = <Json>[];
  for (final t in tasks) {
    final start = fixedStart(t);
    if (start == null) {
      floating.add(t);
      continue;
    }
    final minutes = estimateOf(t);
    final slots = minutes <= estimateDayMinutes
        ? [Slot(t, start, start.add(Duration(minutes: minutes)), 1)]
        : fill(t, minutes, start, useBusy: false);
    for (final s in slots) {
      busy.add((from: s.from, to: s.to));
    }
    add(t, slots, fixed: true);
  }

  // 2. The rest, earliest deadline first, into the remaining free time.
  floating.sort((a, b) {
    final da = a['due'], db = b['due'];
    if (da != null && db != null) {
      final c = DateTime.parse(da).compareTo(DateTime.parse(db));
      if (c != 0) return c;
    } else if (da != null) {
      return -1;
    } else if (db != null) {
      return 1;
    }
    final p = (b['priority'] as int? ?? 1).compareTo(
      a['priority'] as int? ?? 1,
    );
    if (p != 0) return p;
    return (a['title'] as String).compareTo(b['title'] as String);
  });
  // Start at the next quarter of an hour.
  var cursor = DateTime(
    now.year,
    now.month,
    now.day,
    now.hour,
    now.minute,
  ).add(Duration(minutes: (15 - now.minute % 15) % 15));
  for (final t in floating) {
    final slots = fill(t, estimateOf(t), cursor);
    if (slots.isEmpty) continue;
    cursor = slots.last.to;
    add(t, slots);
  }

  for (final list in byDay.values) {
    list.sort((a, b) => a.from.compareTo(b.from));
  }
  items.sort((a, b) => a.slots.first.from.compareTo(b.slots.first.from));
  final suggestions = [
    for (final i in items)
      if (i.late) Suggestion(i.task, i.due!, i.finish),
  ]..sort((a, b) => a.oldDue.compareTo(b.oldDue));
  return Plan(items, byDay, suggestions, ws);
}

/// Moves the due date (and the reminder by the same amount) with a record in
/// the due date history.
Json moveDue(Json task, DateTime newDue, {String reason = ''}) {
  final oldDue = task['due'] == null ? null : DateTime.parse(task['due']);
  final reminder = task['reminder'] == null
      ? null
      : DateTime.parse(task['reminder']);
  final updated = {
    ...task,
    'due': newDue.toUtc().toIso8601String(),
    if (oldDue != null && reminder != null)
      'reminder': newDue
          .subtract(oldDue.difference(reminder))
          .toUtc()
          .toIso8601String(),
  };
  return withDueHistory(task, updated, reason: reason);
}
