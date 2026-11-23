import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'controller.dart';
import 'domain.dart';
import 'planner.dart';
import 'timeline_ui.dart';

const monthNames = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];
const weekdayShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

String two(int n) => n.toString().padLeft(2, '0');
String dayLabel(DateTime d) =>
    '${weekdayShort[d.weekday - 1]}, ${two(d.day)}.${two(d.month)}.${d.year}';
String timeLabel(DateTime d) => '${two(d.hour)}:${two(d.minute)}';
String dateTimeLabel(DateTime d) =>
    '${two(d.day)}.${two(d.month)}.${d.year} ${timeLabel(d)}';
String hours(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m мин';
  return m == 0 ? '$h ч' : '$h ч $m мин';
}

Color loadColor(BuildContext context, double ratio) => ratio >= 0.95
    ? Colors.red.shade400
    : ratio >= 0.6
    ? Colors.orange.shade400
    : Colors.green.shade400;

/// Estimate input: days (8 working hours each), hours, minutes.
class EstimateField extends StatefulWidget {
  final int minutes;
  final ValueChanged<int> onChanged;
  const EstimateField({
    super.key,
    required this.minutes,
    required this.onChanged,
  });
  @override
  State<EstimateField> createState() => _EstimateFieldState();
}

class _EstimateFieldState extends State<EstimateField> {
  late final days = TextEditingController(
    text: '${widget.minutes ~/ estimateDayMinutes}',
  );
  late final hrs = TextEditingController(
    text: '${(widget.minutes % estimateDayMinutes) ~/ 60}',
  );
  late final mins = TextEditingController(text: '${widget.minutes % 60}');

  @override
  void dispose() {
    days.dispose();
    hrs.dispose();
    mins.dispose();
    super.dispose();
  }

  void changed() {
    int v(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
    widget.onChanged(v(days) * estimateDayMinutes + v(hrs) * 60 + v(mins));
  }

  Widget box(TextEditingController c, String label) => SizedBox(
    width: 72,
    child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(3),
      ],
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (_) => changed(),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Предполагаемое время на выполнение'),
      const SizedBox(height: 4),
      Wrap(
        spacing: 12,
        children: [box(days, 'Дней'), box(hrs, 'Часов'), box(mins, 'Минут')],
      ),
      const SizedBox(height: 4),
      const Text(
        '1 день = 8 рабочих часов. По умолчанию 1 час.',
        style: TextStyle(fontSize: 12),
      ),
    ],
  );
}

/// Month calendar with the planned load of each working day.
class CalendarDialog extends StatefulWidget {
  final AppController controller;
  final DateTime? now;
  final void Function(Json task)? onOpen;
  const CalendarDialog({
    super.key,
    required this.controller,
    this.now,
    this.onOpen,
  });
  @override
  State<CalendarDialog> createState() => _CalendarDialogState();
}

class _CalendarDialogState extends State<CalendarDialog> {
  late final DateTime now = widget.now ?? DateTime.now();
  late final Plan plan = widget.controller.plan(now: now);
  late DateTime month = DateTime(now.year, now.month);
  late DateTime selected = DateTime(now.year, now.month, now.day);

  Future<void> openDay(DateTime day) async {
    setState(() => selected = day);
    await showDialog<void>(
      context: context,
      builder: (ctx) => DayTimelineDialog(
        controller: widget.controller,
        plan: plan,
        day: day,
        now: now,
        onOpen: widget.onOpen == null
            ? null
            : (t) {
                Navigator.of(ctx).pop();
                Navigator.of(context).pop();
                widget.onOpen!(t);
              },
      ),
    );
  }

  Map<DateTime, List<Json>> get dueByDay {
    final map = <DateTime, List<Json>>{};
    for (final t in plannable(widget.controller.data)) {
      if (t['due'] == null) continue;
      final d = DateTime.parse(t['due']).toLocal();
      map.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(t);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month);
    final lead = first.weekday - 1;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final dues = dueByDay;
    final late = {for (final s in plan.suggestions) s.task['id']};
    final slots = plan.byDay[selected] ?? const <Slot>[];
    final cap = plan.schedule.capacity(selected);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      title: Row(
        children: [
          IconButton(
            tooltip: 'Предыдущий месяц',
            onPressed: () =>
                setState(() => month = DateTime(month.year, month.month - 1)),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(
              '${monthNames[month.month - 1]} ${month.year}',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: 'Следующий месяц',
            onPressed: () =>
                setState(() => month = DateTime(month.year, month.month + 1)),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (plan.problem != null)
                Text(
                  'Рабочее время: ${plan.problem}',
                  style: TextStyle(color: scheme.error),
                ),
              Row(
                children: [
                  for (final w in weekdayShort)
                    Expanded(
                      child: Center(
                        child: Text(w, style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                ],
              ),
              GridView.count(
                crossAxisCount: 7,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 0.82,
                children: [
                  for (var i = 0; i < lead; i++) const SizedBox(),
                  for (var d = 1; d <= daysInMonth; d++)
                    () {
                      final day = DateTime(month.year, month.month, d);
                      final capacity = plan.schedule.capacity(day);
                      final load = plan.load(day);
                      final ratio = capacity == 0 ? 0.0 : load / capacity;
                      final isSel = day == selected;
                      final isToday =
                          day == DateTime(now.year, now.month, now.day);
                      final dueList = dues[day] ?? const [];
                      final hasLate = dueList.any(
                        (t) => late.contains(t['id']),
                      );
                      return InkWell(
                        key: ValueKey(
                          'day-${day.year}-${day.month}-${day.day}',
                        ),
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => openDay(day),
                        child: Container(
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: isSel ? scheme.primaryContainer : null,
                            border: isToday
                                ? Border.all(color: scheme.primary)
                                : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '$d',
                                style: TextStyle(
                                  color: capacity == 0 ? scheme.outline : null,
                                  fontWeight: isToday ? FontWeight.bold : null,
                                ),
                              ),
                              const SizedBox(height: 2),
                              if (capacity > 0)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: ratio.clamp(0, 1),
                                      minHeight: 5,
                                      color: loadColor(context, ratio),
                                      backgroundColor:
                                          scheme.surfaceContainerHighest,
                                    ),
                                  ),
                                ),
                              SizedBox(
                                height: 10,
                                child: dueList.isEmpty
                                    ? null
                                    : Icon(
                                        Icons.flag,
                                        size: 10,
                                        color: hasLate
                                            ? Colors.red.shade400
                                            : scheme.primary,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }(),
                ],
              ),
              const Text(
                'Полоса — занятость рабочего дня по плану, флажок — срок задачи '
                '(красный — не успевается).',
                style: TextStyle(fontSize: 12),
              ),
              const Divider(),
              Text(
                cap == 0
                    ? '${dayLabel(selected)} — выходной'
                    : '${dayLabel(selected)} — занято ${hours(plan.load(selected))} из ${hours(cap)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                slots.isEmpty
                    ? (cap > 0 ? 'Свободно' : 'Задач нет')
                    : 'Задач в плане: ${slots.length}, '
                          'сроков: ${(dues[selected] ?? const []).length}',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => openDay(selected),
                  icon: const Icon(Icons.view_day_outlined),
                  label: const Text('Шкала времени дня'),
                ),
              ),
              const Text(
                'Нажмите на день — откроется шкала времени.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

/// Work plan by days and suggestions to move due dates.
class PlanningPage extends StatefulWidget {
  final AppController controller;
  final Future<void> Function(Json task)? onOpen;
  final DateTime? now;
  const PlanningPage({
    super.key,
    required this.controller,
    this.onOpen,
    this.now,
  });
  @override
  State<PlanningPage> createState() => _PlanningPageState();
}

class _PlanningPageState extends State<PlanningPage> {
  AppController get c => widget.controller;
  late Plan plan = c.plan(now: widget.now);

  void refresh() => setState(() => plan = c.plan(now: widget.now));

  Future<void> apply(List<Suggestion> list) async {
    final ok = await c.applySuggestions(list);
    if (!mounted) return;
    refresh();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Сроки перенесены: ${list.length}'
              : (c.message ?? 'Не удалось перенести'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final days = plan.byDay.keys.toList()..sort();
    final ws = plan.schedule;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Планирование'),
        actions: [
          IconButton(
            tooltip: 'Пересчитать',
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (plan.problem != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(plan.problem!),
              ),
            ),
          Text(
            'Рабочее время: ${ws.days.length} дн. в неделю, ${hm(ws.start)}–${hm(ws.end)}'
            '${ws.hasBreak ? ', перерыв ${hm(ws.breakStart)}–${hm(ws.breakEnd)}' : ''}. '
            'Изменить: Настройки → Рабочее время.',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.timeline),
              title: Text(
                plan.items.isEmpty
                    ? 'Нет активных задач для планирования'
                    : 'В плане задач: ${plan.items.length}, работы: ${estimateLabel(plan.totalMinutes)}',
              ),
              subtitle: plan.end == null
                  ? null
                  : Text('Всё будет выполнено к ${dateTimeLabel(plan.end!)}'),
            ),
          ),
          if (plan.suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Предложения по переносу сроков',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                FilledButton(
                  onPressed: c.busy ? null : () => apply(plan.suggestions),
                  child: const Text('Перенести все'),
                ),
              ],
            ),
            const Text(
              'Эти задачи не успеваются в рабочее время до своего срока. '
              'Предлагаемый срок — когда задача будет выполнена по плану.',
              style: TextStyle(fontSize: 12),
            ),
            for (final s in plan.suggestions)
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.warning_amber,
                    color: Colors.orange.shade400,
                  ),
                  title: Text(s.task['title']),
                  subtitle: Text(
                    'Срок ${dateTimeLabel(s.oldDue)} → ${dateTimeLabel(s.newDue)}\n'
                    'Оценка ${estimateLabel(estimateOf(s.task))}'
                    '${s.oldDue.isBefore(widget.now ?? DateTime.now()) ? ' • срок уже прошёл' : ''}',
                  ),
                  isThreeLine: true,
                  trailing: TextButton(
                    onPressed: c.busy ? null : () => apply([s]),
                    child: const Text('Перенести'),
                  ),
                ),
              ),
          ] else if (plan.items.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Все задачи со сроком успеваются — переносить ничего не нужно.',
              ),
            ),
          const SizedBox(height: 8),
          for (final d in days) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                '${dayLabel(d)} — ${hours(plan.load(d))} из ${hours(ws.capacity(d))}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final s in plan.byDay[d]!)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Text('${timeLabel(s.from)}\n${timeLabel(s.to)}'),
                title: Text(s.task['title']),
                subtitle: Text(
                  [
                    if (s.parts > 1) 'часть ${s.part} из ${s.parts}',
                    if (s.task['due'] != null)
                      'срок ${dateTimeLabel(DateTime.parse(s.task['due']).toLocal())}',
                    if (s.task['priority'] == 2) 'высокий приоритет',
                  ].join(' • '),
                ),
                onTap: widget.onOpen == null
                    ? null
                    : () async {
                        await widget.onOpen!(s.task);
                        if (mounted) refresh();
                      },
              ),
          ],
        ],
      ),
    );
  }
}

/// Settings → working time.
class WorkTimePage extends StatefulWidget {
  final AppController controller;
  const WorkTimePage({super.key, required this.controller});
  @override
  State<WorkTimePage> createState() => _WorkTimePageState();
}

class _WorkTimePageState extends State<WorkTimePage> {
  late WorkSchedule ws = widget.controller.workSchedule;
  String? status;

  WorkSchedule copy({
    Set<int>? days,
    int? start,
    int? end,
    bool? hasBreak,
    int? breakStart,
    int? breakEnd,
  }) => WorkSchedule(
    days: days ?? ws.days,
    start: start ?? ws.start,
    end: end ?? ws.end,
    hasBreak: hasBreak ?? ws.hasBreak,
    breakStart: breakStart ?? ws.breakStart,
    breakEnd: breakEnd ?? ws.breakEnd,
  );

  Future<int?> time(int value) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: value ~/ 60, minute: value % 60),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    return t == null ? null : t.hour * 60 + t.minute;
  }

  Widget timeTile(String label, int value, void Function(int) set) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    trailing: OutlinedButton(
      onPressed: () async {
        final v = await time(value);
        if (v != null) setState(() => set(v));
      },
      child: Text(hm(value)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final problem = ws.problem;
    final week = [
      for (var d = 1; d <= 7; d++) ws.capacity(DateTime(2024, 1, d)),
    ].fold(0, (a, b) => a + b); // 1 Jan 2024 is a Monday
    return Scaffold(
      appBar: AppBar(title: const Text('Рабочее время')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Рабочие дни'),
          Wrap(
            spacing: 6,
            children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(weekdayShort[d - 1]),
                  selected: ws.days.contains(d),
                  onSelected: (v) => setState(
                    () => ws = copy(
                      days: v ? ({...ws.days, d}) : ({...ws.days}..remove(d)),
                    ),
                  ),
                ),
            ],
          ),
          timeTile('Начало рабочего дня', ws.start, (v) => ws = copy(start: v)),
          timeTile('Конец рабочего дня', ws.end, (v) => ws = copy(end: v)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Перерыв'),
            value: ws.hasBreak,
            onChanged: (v) => setState(() => ws = copy(hasBreak: v)),
          ),
          if (ws.hasBreak) ...[
            timeTile(
              'Начало перерыва',
              ws.breakStart,
              (v) => ws = copy(breakStart: v),
            ),
            timeTile(
              'Конец перерыва',
              ws.breakEnd,
              (v) => ws = copy(breakEnd: v),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            problem ?? 'Рабочих часов в неделю: ${hours(week)}',
            style: TextStyle(
              color: problem == null
                  ? null
                  : Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Используется для календаря занятости и планирования. '
            'Настраивается на каждом устройстве отдельно.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton(
                onPressed: problem != null
                    ? null
                    : () async {
                        final ok = await ws.save(widget.controller.prefs);
                        setState(
                          () => status = ok
                              ? 'Сохранено'
                              : 'Не удалось сохранить',
                        );
                      },
                child: const Text('Сохранить'),
              ),
              const SizedBox(width: 12),
              if (status != null) Text(status!),
            ],
          ),
        ],
      ),
    );
  }
}
