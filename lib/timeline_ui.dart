import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'controller.dart';
import 'domain.dart';
import 'planner.dart';
import 'planner_ui.dart';
import 'row_ui.dart';

/// A block on the day timeline.
class TimelineBlock {
  final Json task;
  final DateTime from;
  final DateTime to;
  final String? note; // "часть 1 из 2", "выполняется"
  final bool fact;
  final bool late;
  final bool fixed;
  TimelineBlock(
    this.task,
    this.from,
    this.to, {
    this.note,
    this.fixed = false,
    this.fact = false,
    this.late = false,
  });
}

DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// Side-by-side columns for overlapping blocks: for each block its column
/// and the number of columns in its group of overlapping blocks.
/// [minMinutes] — the shortest drawn block: short blocks are drawn taller
/// than their time, so they are laid out by their drawn size.
List<({int col, int cols})> columnsFor(
  List<TimelineBlock> blocks, {
  int minMinutes = 0,
}) {
  DateTime endOf(TimelineBlock b) {
    final min = b.from.add(Duration(minutes: minMinutes));
    return b.to.isAfter(min) ? b.to : min;
  }

  final order = [for (var i = 0; i < blocks.length; i++) i]
    ..sort((a, b) => blocks[a].from.compareTo(blocks[b].from));
  final cols = List<int>.filled(blocks.length, 0);
  final count = List<int>.filled(blocks.length, 1);
  var group = <int>[];
  DateTime? groupEnd;
  final colEnds = <DateTime>[];
  void close() {
    for (final g in group) {
      count[g] = colEnds.isEmpty ? 1 : colEnds.length;
    }
    group = [];
    colEnds.clear();
    groupEnd = null;
  }

  for (final i in order) {
    final b = blocks[i];
    if (groupEnd != null && !b.from.isBefore(groupEnd!)) close();
    var col = colEnds.indexWhere((e) => !b.from.isBefore(e));
    if (col < 0) {
      col = colEnds.length;
      colEnds.add(endOf(b));
    } else {
      colEnds[col] = endOf(b);
    }
    cols[i] = col;
    group.add(i);
    if (groupEnd == null || endOf(b).isAfter(groupEnd!)) groupEnd = endOf(b);
  }
  close();
  return [
    for (var i = 0; i < blocks.length; i++) (col: cols[i], cols: count[i]),
  ];
}

/// Planned blocks of a day.
List<TimelineBlock> plannedBlocks(Plan plan, DateTime day) {
  final late = {for (final s in plan.suggestions) s.task['id']};
  return [
    for (final s in plan.byDay[dayStart(day)] ?? const <Slot>[])
      TimelineBlock(
        s.task,
        s.from,
        s.to,
        fixed: s.fixed,
        note: [
          if (!s.fixed) 'по плану',
          if (s.parts > 1) 'часть ${s.part} из ${s.parts}',
        ].join(' • '),
        late: late.contains(s.task['id']),
      ),
  ];
}

/// Actual work of a day: tasks with a start time, cut to the day; a task
/// still in progress lasts until now.
List<TimelineBlock> factBlocks(Dataset data, DateTime day, DateTime now) {
  final from0 = dayStart(day), to0 = from0.add(const Duration(days: 1));
  final result = <TimelineBlock>[];
  for (final t in data.visible('task')) {
    if (t['startedAt'] == null || !onTimeline(t)) continue;
    final start = DateTime.parse(t['startedAt']).toLocal();
    final done = t['done'] == true;
    final running = !done || t['finishedAt'] == null;
    var end = t['finishedAt'] == null
        ? now
        : DateTime.parse(t['finishedAt']).toLocal();
    // Not done yet: only the part that has already passed is a fact; the
    // planned rest is in the "План" column.
    if (!done && end.isAfter(now)) end = now;
    final a = start.isBefore(from0) ? from0 : start;
    final b = end.isAfter(to0) ? to0 : end;
    if (!b.isAfter(a)) continue;
    result.add(
      TimelineBlock(
        t,
        a,
        b,
        fact: true,
        note: running ? 'выполняется' : 'выполнено',
      ),
    );
  }
  result.sort((x, y) => x.from.compareTo(y.from));
  return result;
}

/// Tasks due on the day.
List<Json> dueOn(Dataset data, DateTime day) => [
  for (final t in plannable(data))
    if (t['due'] != null &&
        dayStart(DateTime.parse(t['due']).toLocal()) == dayStart(day))
      t,
]..sort((a, b) => (a['due'] as String).compareTo(b['due']));

class _GridPainter extends CustomPainter {
  final double hour;
  final List<({double top, double bottom})> work;
  final ({double top, double bottom})? lunch;
  final Color off, on, line, faint;
  _GridPainter({
    required this.hour,
    required this.work,
    required this.lunch,
    required this.off,
    required this.on,
    required this.line,
    required this.faint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = off);
    for (final w in work) {
      canvas.drawRect(
        Rect.fromLTRB(0, w.top, size.width, w.bottom),
        Paint()..color = on,
      );
    }
    if (lunch != null) {
      final p = Paint()
        ..color = faint
        ..strokeWidth = 1;
      for (var x = -size.width; x < size.width; x += 10) {
        canvas.save();
        canvas.clipRect(
          Rect.fromLTRB(0, lunch!.top, size.width, lunch!.bottom),
        );
        canvas.drawLine(
          Offset(x, lunch!.bottom),
          Offset(x + (lunch!.bottom - lunch!.top), lunch!.top),
          p,
        );
        canvas.restore();
      }
    }
    for (var h = 0; h <= 24; h++) {
      canvas.drawLine(
        Offset(0, h * hour),
        Offset(size.width, h * hour),
        Paint()..color = line,
      );
      if (h < 24) {
        final y = h * hour + hour / 2;
        for (var x = 0.0; x < size.width; x += 8) {
          canvas.drawLine(
            Offset(x, y),
            Offset(x + 3, y),
            Paint()..color = faint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => true;
}

/// A day as a vertical time scale: working hours, break, planned tasks,
/// actual work, deadlines and the current time.
class DayTimelineDialog extends StatefulWidget {
  final AppController controller;
  final Plan plan;
  final DateTime day;
  final DateTime? now;
  final void Function(Json task)? onOpen;
  const DayTimelineDialog({
    super.key,
    required this.controller,
    required this.plan,
    required this.day,
    this.now,
    this.onOpen,
  });
  @override
  State<DayTimelineDialog> createState() => _DayTimelineDialogState();
}

class _DayTimelineDialogState extends State<DayTimelineDialog> {
  static const zooms = [48.0, 72.0, 110.0, 160.0];
  int zoom = 2;
  double get hour => zooms[zoom];
  static const minBlock = 20.0;
  int get minMinutes => (minBlock * 60 / hour).ceil();
  static const axis = 46.0;
  late DateTime day = dayStart(widget.day);
  late final DateTime now = widget.now ?? DateTime.now();
  final scroll = ScrollController();

  double y(DateTime t) =>
      (t.difference(day).inMinutes.clamp(0, 24 * 60)) * hour / 60;
  double ym(int minutes) => minutes * hour / 60;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  /// Scrolls to the first event or the start of the working day.
  void jump() {
    if (!scroll.hasClients) return;
    final ws = widget.plan.schedule;
    final times = <double>[
      ym(ws.start),
      ...plannedBlocks(widget.plan, day).map((b) => y(b.from)),
      ...factBlocks(widget.controller.data, day, now).map((b) => y(b.from)),
      ...dueOn(
        widget.controller.data,
        day,
      ).map((t) => y(DateTime.parse(t['due']).toLocal())),
      if (dayStart(now) == day) y(now),
    ];
    final first = times.reduce(math.min);
    scroll.jumpTo(
      (first - hour * 0.75).clamp(0, scroll.position.maxScrollExtent),
    );
  }

  /// Changes the scale keeping the middle of the view in place.
  void rezoom(int delta) {
    final old = hour;
    final mid = scroll.hasClients
        ? (scroll.offset + scroll.position.viewportDimension / 2) / old
        : 9.0;
    setState(() => zoom = (zoom + delta).clamp(0, zooms.length - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients) return;
      scroll.jumpTo(
        (mid * hour - scroll.position.viewportDimension / 2).clamp(
          0,
          scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  void go(int delta) {
    setState(() => day = DateTime(day.year, day.month, day.day + delta));
    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
  }

  Widget block(
    BuildContext context,
    TimelineBlock b,
    double left,
    double width,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final top = y(b.from);
    final height = math.max(y(b.to) - top, minBlock);
    final base = b.fact
        ? scheme.tertiary
        : rowColor(b.task['color']) ?? scheme.primary;
    final project = widget.controller.data
        .visible('project')
        .where((p) => p['id'] == b.task['projectId'])
        .firstOrNull;
    final info = [
      '${timeLabel(b.from)}–${timeLabel(b.to)}',
      if (project != null) project['name'] as String,
      if (b.note?.isNotEmpty == true) b.note!,
      if (b.late) 'не успевается к сроку',
    ].join(' • ');
    return Positioned(
      key: ValueKey(
        'block-${b.fact ? 'fact' : 'plan'}-${b.task['id']}-${b.from.millisecondsSinceEpoch}',
      ),
      top: top + 1,
      left: left,
      width: width,
      height: height - 2,
      child: Tooltip(
        message: '${b.task['title']}\n$info',
        child: Material(
          color: base.withValues(
            alpha: b.fact ? 0.30 : (b.fixed ? 0.40 : 0.04),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(
              color: b.late
                  ? Colors.red.shade400
                  : base.withValues(alpha: b.fixed || b.fact ? 1 : 0.45),
              width: b.late ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen == null ? null : () => widget.onOpen!(b.task),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: b.late ? Colors.red.shade400 : base),
                Expanded(
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      maxHeight: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.task['title'],
                              maxLines: height > 60 ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                decoration: b.task['done'] == true
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            if (height > 36)
                              Text(
                                info,
                                maxLines: height > 70
                                    ? 3
                                    : (height > 52 ? 2 : 1),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ws = widget.plan.schedule;
    final data = widget.controller.data;
    final planned = plannedBlocks(widget.plan, day);
    final facts = factBlocks(data, day, now);
    final dues = dueOn(data, day);
    final late = {for (final s in widget.plan.suggestions) s.task['id']};
    final cap = ws.capacity(day);
    final load = widget.plan.load(day);
    final work = [
      for (final i in ws.intervals(day)) (top: y(i.from), bottom: y(i.to)),
    ];
    final lunch = cap > 0 && ws.hasBreak
        ? (top: ym(ws.breakStart), bottom: ym(ws.breakEnd))
        : null;
    final isToday = dayStart(now) == day;
    final media = MediaQuery.sizeOf(context);

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      title: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Предыдущий день',
                onPressed: () => go(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${isToday ? 'Сегодня, ' : ''}${dayLabel(day)}',
                  key: const ValueKey('timeline-title'),
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: 'Следующий день',
                onPressed: () => go(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  cap == 0
                      ? 'Выходной${planned.isEmpty ? '' : ' • запланировано ${hours(load)}'}'
                      : 'Занято ${hours(load)} из ${hours(cap)} • свободно ${hours(math.max(0, cap - load))}',
                  style: TextStyle(
                    fontSize: 13,
                    color: cap > 0
                        ? loadColor(context, load / cap)
                        : scheme.outline,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Мельче',
                visualDensity: VisualDensity.compact,
                onPressed: zoom == 0 ? null : () => rezoom(-1),
                icon: const Icon(Icons.zoom_out, size: 20),
              ),
              IconButton(
                tooltip: 'Крупнее',
                visualDensity: VisualDensity.compact,
                onPressed: zoom == zooms.length - 1 ? null : () => rezoom(1),
                icon: const Icon(Icons.zoom_in, size: 20),
              ),
            ],
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: math.min(media.height * 0.68, 680),
        child: LayoutBuilder(
          builder: (context, box) {
            final area = box.maxWidth - axis;
            final hasFact = facts.isNotEmpty;
            final planWidth = hasFact ? area * 0.6 - 4 : area - 4;
            final factLeft = axis + planWidth + 6;
            final factWidth = area - planWidth - 10;
            return Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: axis),
                    SizedBox(
                      width: planWidth,
                      child: Text(
                        'План (${planned.length})',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (hasFact)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            'Факт (${facts.length})',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('timeline-scroll'),
                    controller: scroll,
                    child: SizedBox(
                      height: 24 * hour + 12,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: axis,
                            right: 0,
                            top: 0,
                            height: 24 * hour,
                            child: CustomPaint(
                              painter: _GridPainter(
                                hour: hour,
                                work: work,
                                lunch: lunch,
                                // Non-working time is dimmed, working time
                                // is tinted — readable in both themes.
                                off: scheme.onSurface.withValues(alpha: 0.05),
                                on: scheme.primary.withValues(alpha: 0.11),
                                line: scheme.outlineVariant,
                                faint: scheme.outlineVariant.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ),
                          for (var h = 0; h <= 24; h++)
                            Positioned(
                              left: 0,
                              width: axis - 6,
                              top: h * hour - 8,
                              child: Text(
                                '${two(h)}:00',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      work.any(
                                        (w) =>
                                            h * hour >= w.top &&
                                            h * hour <= w.bottom,
                                      )
                                      ? null
                                      : scheme.outline,
                                ),
                              ),
                            ),
                          if (lunch != null)
                            Positioned(
                              left: axis,
                              right: 0,
                              top: lunch.top,
                              height: lunch.bottom - lunch.top,
                              child: IgnorePointer(
                                child: Center(
                                  child: Text(
                                    'Перерыв',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (cap == 0)
                            Positioned(
                              left: axis,
                              right: 0,
                              top: ym(ws.start),
                              child: IgnorePointer(
                                child: Center(
                                  child: Text(
                                    'Выходной — задачи не планируются',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          for (final (k, c) in columnsFor(
                            planned,
                            minMinutes: minMinutes,
                          ).indexed)
                            block(
                              context,
                              planned[k],
                              axis + 2 + planWidth / c.cols * c.col,
                              planWidth / c.cols - (c.cols > 1 ? 2 : 0),
                            ),
                          for (final (k, c) in columnsFor(
                            facts,
                            minMinutes: minMinutes,
                          ).indexed)
                            block(
                              context,
                              facts[k],
                              factLeft + factWidth / c.cols * c.col,
                              factWidth / c.cols - (c.cols > 1 ? 2 : 0),
                            ),
                          for (final t in dues)
                            () {
                              final at = DateTime.parse(t['due']).toLocal();
                              final red = late.contains(t['id']);
                              final color = red
                                  ? Colors.red.shade400
                                  : scheme.primary;
                              return Positioned(
                                key: ValueKey('due-${t['id']}'),
                                left: axis,
                                right: 0,
                                top: y(at) - 1,
                                child: IgnorePointer(
                                  ignoring: widget.onOpen == null,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Container(height: 2, color: color),
                                      GestureDetector(
                                        onTap: widget.onOpen == null
                                            ? null
                                            : () => widget.onOpen!(t),
                                        child: Container(
                                          constraints: BoxConstraints(
                                            maxWidth: area * 0.75,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: color,
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                  bottom: Radius.circular(6),
                                                ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                Icons.flag,
                                                size: 12,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 3),
                                              Flexible(
                                                child: Text(
                                                  'Срок ${timeLabel(at)}: ${t['title']}${red ? ' — не успевается' : ''}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }(),
                          if (isToday)
                            Positioned(
                              key: const ValueKey('timeline-now'),
                              left: axis - 5,
                              right: 0,
                              top: y(now) - 5,
                              child: IgnorePointer(
                                child: Row(
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      decoration: const BoxDecoration(
                                        color: Colors.redAccent,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    Expanded(
                                      child: Container(
                                        height: 2,
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    [
                      'Яркие блоки — время из задачи («Начало выполнения»), '
                          'бледные — предложение плана',
                      'подсвечено — рабочее время, штриховка — перерыв',
                      'красная линия — сейчас',
                      if (widget.onOpen != null)
                        'нажмите на блок — откроется задача',
                    ].join(', '),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            );
          },
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
