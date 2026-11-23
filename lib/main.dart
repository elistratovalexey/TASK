import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud.dart';
import 'controller.dart';
import 'domain.dart';
import 'knowledge.dart';
import 'mail_ui.dart';
import 'export_ui.dart';
import 'planner.dart';
import 'planner_ui.dart';
import 'rich_text.dart';
import 'people.dart';
import 'shopping.dart';
import 'row_ui.dart';
import 'attachments_ui.dart';
import 'storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final c = AppController(
      await Repository.open(),
      await SharedPreferences.getInstance(),
    );
    await c.load();
    runApp(TaskApplication(controller: c));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(
                'Не удалось открыть хранилище. Данные не изменены.\n$e',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const colors = <String, Color>{
  'Индиго': Colors.indigo,
  'Зелёный': Colors.teal,
  'Синий': Colors.blue,
  'Оранжевый': Colors.deepOrange,
};
const repeatNames = {
  'none': 'Не повторять',
  'daily': 'Ежедневно',
  'weekly': 'Еженедельно',
  'monthly': 'Ежемесячно',
};

/// How many times the due date of a task was changed after it was set.
int dueMoves(Json task) => ((task['dueHistory'] as List?) ?? const [])
    .where((h) => h['from'] != null)
    .length;

String dueChangeLabel(Json h) {
  if (h['from'] == null) return 'Срок назначен: ${dateLabel(h['to'])}';
  if (h['to'] == null) return 'Срок снят (был ${dateLabel(h['from'])})';
  final from = DateTime.parse(h['from']);
  final to = DateTime.parse(h['to']);
  final days = to.difference(from).inHours / 24;
  final shift = days.abs() < 1
      ? ''
      : ' (${days > 0 ? '+' : '−'}${days.abs().round()} дн.)';
  return '${dateLabel(h['from'])} → ${dateLabel(h['to'])}$shift';
}

/// Work time line for a task card.
String? workLabel(Json t, {DateTime? now}) {
  final spent = spentTime(t);
  if (spent != null) return 'Выполнено за ${durationLabel(spent)}';
  if (t['startedAt'] != null) {
    final s = DateTime.parse(t['startedAt']);
    final n = now ?? DateTime.now();
    return s.isAfter(n)
        ? 'Начало: ${dateLabel(t['startedAt'])}'
        : 'В работе ${durationLabel(n.difference(s))} (с ${dateLabel(t['startedAt'])})';
  }
  if (t['finishedAt'] != null) {
    return 'Выполнено: ${dateLabel(t['finishedAt'])}';
  }
  return null;
}

class WorkTimeEditor extends StatelessWidget {
  final String? startedAt;
  final String? finishedAt;
  final Future<String?> Function(String?) pick;
  final void Function(String? startedAt, String? finishedAt) onChanged;

  /// "Рассчитать": due time minus the estimate (null — no due time).
  final String? Function()? calcStart;
  const WorkTimeEditor({
    super.key,
    required this.startedAt,
    required this.finishedAt,
    required this.pick,
    required this.onChanged,
    this.calcStart,
  });

  static String nowIso() => DateTime.now().toUtc().toIso8601String();

  @override
  Widget build(BuildContext context) {
    final spent = spentTime({'startedAt': startedAt, 'finishedAt': finishedAt});
    final wrong = spent != null && spent.isNegative;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Начало выполнения: ${dateLabel(startedAt)}'),
        Wrap(
          children: [
            TextButton(
              onPressed: () => onChanged(nowIso(), finishedAt),
              child: const Text('Сейчас'),
            ),
            TextButton(
              onPressed: () async =>
                  onChanged(await pick(startedAt), finishedAt),
              child: const Text('Указать'),
            ),
            if (calcStart != null)
              Tooltip(
                message: 'Срок минус предполагаемое время',
                child: TextButton(
                  key: const ValueKey('calc-start'),
                  onPressed: calcStart!() == null
                      ? null
                      : () => onChanged(calcStart!(), finishedAt),
                  child: const Text('Рассчитать'),
                ),
              ),
            if (startedAt != null)
              TextButton(
                onPressed: () => onChanged(null, finishedAt),
                child: const Text('Убрать'),
              ),
          ],
        ),
        Text('Окончание выполнения: ${dateLabel(finishedAt)}'),
        Wrap(
          children: [
            TextButton(
              onPressed: () => onChanged(startedAt, nowIso()),
              child: const Text('Сейчас'),
            ),
            TextButton(
              onPressed: () async =>
                  onChanged(startedAt, await pick(finishedAt)),
              child: const Text('Указать'),
            ),
            if (finishedAt != null)
              TextButton(
                onPressed: () => onChanged(startedAt, null),
                child: const Text('Убрать'),
              ),
          ],
        ),
        if (spent != null)
          Text(
            wrong
                ? 'Окончание раньше начала — исправьте время'
                : 'Затрачено: ${durationLabel(spent)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: wrong ? Theme.of(context).colorScheme.error : null,
            ),
          )
        else if (startedAt != null &&
            !DateTime.parse(startedAt!).isAfter(DateTime.now()))
          Text(
            'В работе: ${durationLabel(DateTime.now().difference(DateTime.parse(startedAt!)))}',
          ),
        const Text(
          'При отметке «выполнено» время окончания ставится автоматически.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

String dateLabel(String? value) {
  if (value == null) return 'Не задано';
  final d = DateTime.parse(value).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

class TaskApplication extends StatelessWidget {
  final AppController controller;
  const TaskApplication({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      final seed = colors[controller.prefs.getString('color')] ?? Colors.indigo;
      final mode = controller.prefs.getString('theme') ?? 'system';
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Мои проекты',
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: seed,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        themeMode: mode == 'dark'
            ? ThemeMode.dark
            : mode == 'light'
            ? ThemeMode.light
            : ThemeMode.system,
        home: TaskApp(controller: controller),
      );
    },
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String text, {
  String action = 'Продолжить',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class TaskApp extends StatefulWidget {
  final AppController controller;
  const TaskApp({super.key, required this.controller});
  @override
  State<TaskApp> createState() => _TaskAppState();
}

class _TaskAppState extends State<TaskApp> with WidgetsBindingObserver {
  AppController get c => widget.controller;
  String projectId = '';
  String filter = 'Активные';
  String query = '';
  String personId = '';
  int tab = 0;
  final knowledge = GlobalKey<KnowledgeViewState>();
  final shopping = GlobalKey<ShoppingViewState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!c.ready) return;
    if (state == AppLifecycleState.resumed) {
      if (!c.busy) {
        c.run(() async {
          await c.schedule();
        });
      }
      if (c.autoSync) c.sync(silent: true);
    }
    if (state == AppLifecycleState.paused && c.autoSync) {
      c.sync(silent: true); // Send fresh edits before Android stops the app.
    }
  }

  Future<void> project([Json? old, String? parent]) async {
    final result = await showDialog<Json>(
      context: context,
      builder: (_) => ProjectEditor(
        projects: c.data.visible('project'),
        old: old,
        parentId: old?['parentId'] ?? parent,
      ),
    );
    if (result != null) await c.save('project', result);
  }

  Future<void> deleteProject(Json p) async {
    final tree = ProjectTree(c.data.visible('project'));
    final ids = tree.subtree(p['id']);
    final tasks = c.data
        .visible('task')
        .where((t) => ids.contains(t['projectId']))
        .length;
    final yes = await confirm(
      context,
      'Удалить проект?',
      '«${tree.path(p['id'])}»\n'
          'Подпроектов: ${ids.length - 1}, задач: $tasks. '
          'Всё это будет удалено на всех устройствах после синхронизации. '
          'Перед удалением сохраняется автоматическая копия.',
      action: 'Удалить',
    );
    if (!yes) return;
    if (await c.deleteProject(p['id'])) setState(() => projectId = '');
  }

  Future<void> planning() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlanningPage(
        controller: c,
        onOpen: (t) async {
          final fresh = c.data
              .visible('task')
              .where((x) => x['id'] == t['id'])
              .firstOrNull;
          if (fresh != null) await edit(fresh);
        },
      ),
    ),
  );

  /// Opens inbox tasks one by one until all are sorted or the user cancels.
  Future<void> triage() async {
    final seen = <String>{};
    while (mounted) {
      final next = c.inboxTasks
          .where((t) => !seen.contains(t['id']))
          .firstOrNull;
      if (next == null) break;
      seen.add(next['id']);
      if (!await edit(next)) break;
    }
  }

  /// Returns true if the task was saved.
  Future<bool> edit([Json? task]) async {
    var projects = c.data.visible('project');
    if (projects.isEmpty) {
      await project();
      projects = c.data.visible('project');
      if (projects.isEmpty || task == null) return false;
    }
    if (!mounted) return false;
    final value = await showDialog<Json>(
      context: context,
      builder: (_) => TaskEditor(
        controller: c,
        projects: projects,
        old: task,
        projectId: projects.any((p) => p['id'] == projectId)
            ? projectId
            : projects.first['id'],
      ),
    );
    if (value == null) return false;
    return c.save('task', value);
  }

  Future<void> sync() async {
    if (c.provider == 'none') {
      await settings();
      return;
    }
    await c.sync();
  }

  Future<void> settings() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => SettingsPage(controller: c)),
  );

  @override
  Widget build(BuildContext context) {
    final projects = c.data.visible('project');
    final tree = ProjectTree(projects);
    final selected = tree.byId.containsKey(projectId) ? projectId : '';
    final scope = selected.isEmpty ? null : tree.subtree(selected);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final visible =
        c.data.visible('task').where((t) {
          if (scope != null && !scope.contains(t['projectId'])) return false;
          if (personId.isNotEmpty &&
              !((t['people'] as List?) ?? const []).contains(personId)) {
            return false;
          }
          if (!'${t['title']} ${t['notes']} ${involvedNames(c.data, t).join(' ')}'
              .toLowerCase()
              .contains(query.toLowerCase())) {
            return false;
          }
          final due = t['due'] == null
              ? null
              : DateTime.parse(t['due']).toLocal();
          switch (filter) {
            case 'Активные':
              return t['done'] != true;
            case 'Сегодня':
              return t['done'] != true &&
                  due != null &&
                  !due.isBefore(today) &&
                  due.isBefore(DateTime(now.year, now.month, now.day + 1));
            case 'Ближайшие':
              return t['done'] != true &&
                  due != null &&
                  !due.isBefore(today) &&
                  due.isBefore(DateTime(now.year, now.month, now.day + 8));
            case 'Просроченные':
              return t['done'] != true && due != null && due.isBefore(now);
            case 'Выполненные':
              return t['done'] == true;
            default:
              return true;
          }
        }).toList()..sort((a, b) {
          final done = (a['done'] == true ? 1 : 0).compareTo(
            b['done'] == true ? 1 : 0,
          );
          if (done != 0) return done;
          final ad = a['due'] == null
              ? DateTime(9999)
              : DateTime.parse(a['due']);
          final bd = b['due'] == null
              ? DateTime(9999)
              : DateTime.parse(b['due']);
          return ad.compareTo(bd);
        });
    return Scaffold(
      appBar: AppBar(
        title: Text(
          tab == 2
              ? 'Покупки'
              : tab == 1
              ? 'База знаний'
              : MediaQuery.sizeOf(context).width < 430
              ? 'Проекты'
              : 'Мои проекты',
        ),
        actions: [
          IconButton(
            tooltip: c.syncing
                ? (c.syncProgress ?? 'Синхронизация…')
                : c.syncError != null
                ? 'Ошибка синхронизации: ${c.syncError}'
                : c.provider == 'none'
                ? 'Облако не подключено'
                : 'Синхронизировать сейчас',
            onPressed: c.syncing || !c.ready ? null : sync,
            icon: c.syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    c.provider == 'none'
                        ? Icons.cloud_off_outlined
                        : c.syncError != null
                        ? Icons.sync_problem
                        : Icons.cloud_done_outlined,
                    color: c.syncError != null
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
          ),
          IconButton(
            tooltip: 'Календарь занятости',
            onPressed: !c.ready
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => CalendarDialog(
                      controller: c,
                      onOpen: (t) async {
                        final fresh = c.data
                            .visible('task')
                            .where((x) => x['id'] == t['id'])
                            .firstOrNull;
                        if (fresh != null) await edit(fresh);
                      },
                    ),
                  ),
            icon: const Icon(Icons.calendar_month_outlined),
          ),
          IconButton(
            tooltip: 'Планирование',
            onPressed: !c.ready ? null : planning,
            icon: const Icon(Icons.view_timeline_outlined),
          ),
          IconButton(
            tooltip: 'Настройки',
            onPressed: c.busy || !c.ready ? null : settings,
            icon: const Icon(Icons.settings_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            enabled: c.ready,
            onSelected: (v) => showDialog<void>(
              context: context,
              builder: (_) => v == 'excel'
                  ? ExportDialog(controller: c)
                  : UpdateDialog(controller: c),
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'excel',
                child: ListTile(
                  leading: Icon(Icons.table_view_outlined),
                  title: Text('Задачи в Excel на почту'),
                ),
              ),
              PopupMenuItem(
                value: 'update',
                child: ListTile(
                  leading: Icon(Icons.system_update_outlined),
                  title: Text('Проверить обновление'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: c.ready && c.fatal == null && tab == 2
          ? ShoppingView(key: shopping, controller: c)
          : c.ready && c.fatal == null && tab == 1
          ? KnowledgeView(key: knowledge, controller: c)
          : c.fatal != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText(c.fatal!),
              ),
            )
          : !c.ready
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  children: [
                    if (c.busy) const LinearProgressIndicator(),
                    if (c.warning != null)
                      _notice(c.warning!, Icons.notifications_off_outlined),
                    if (c.message != null)
                      _notice(c.message!, Icons.info_outline),
                    if (c.syncError != null && !c.syncing)
                      _notice(
                        'Автосинхронизация: ${c.syncError}',
                        Icons.sync_problem,
                      ),
                    if (c.mailError != null && !c.checkingMail)
                      _notice(
                        'Почта: ${c.mailError}',
                        Icons.mail_lock_outlined,
                      ),
                    if (c.inboxTasks.isNotEmpty)
                      Card(
                        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        color: Theme.of(context).colorScheme.primaryContainer,
                        child: ListTile(
                          leading: const Icon(Icons.move_to_inbox),
                          title: Text(
                            'Из почты: ${c.inboxTasks.length} — выберите проект и сроки',
                          ),
                          trailing: FilledButton(
                            onPressed: c.busy ? null : triage,
                            child: const Text('Разобрать'),
                          ),
                        ),
                      ),
                    if (c.data.conflicts.isNotEmpty)
                      ListTile(
                        leading: const Icon(Icons.warning_amber),
                        title: Text('Конфликтов: ${c.data.conflicts.length}'),
                        subtitle: const Text(
                          'Правки сохранены. Выберите нужные версии.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: c.busy
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ConflictsPage(controller: c),
                                ),
                              ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(
                                'project:$selected:${projects.length}',
                              ),
                              initialValue: selected,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Проект',
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('Все проекты'),
                                ),
                                ...projectItems(tree),
                              ],
                              onChanged: c.busy
                                  ? null
                                  : (v) => setState(() => projectId = v!),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Создать проект',
                            onPressed: c.busy ? null : project,
                            icon: const Icon(Icons.create_new_folder_outlined),
                          ),
                          if (selected.isNotEmpty)
                            PopupMenuButton<String>(
                              tooltip: 'Действия с проектом',
                              enabled: !c.busy,
                              onSelected: (v) {
                                final p = tree.byId[selected]!;
                                if (v == 'sub') project(null, selected);
                                if (v == 'edit') project(p);
                                if (v == 'delete') deleteProject(p);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'sub',
                                  child: Text('Добавить подпроект'),
                                ),
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Переименовать / переместить'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Удалить с подпроектами'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    if (c.data.visible('person').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('person-$personId'),
                          initialValue: peopleById(c.data).containsKey(personId)
                              ? personId
                              : '',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Задействован',
                            prefixIcon: Icon(Icons.person_outline),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('Все люди'),
                            ),
                            for (final p in peopleList(c.data))
                              DropdownMenuItem(
                                value: p['id'] as String,
                                child: Text(
                                  p['name'],
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => personId = v ?? ''),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: 'Поиск по задачам и заметкам',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (v) => setState(() => query = v),
                      ),
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          for (final f in [
                            'Все',
                            'Активные',
                            'Сегодня',
                            'Ближайшие',
                            'Просроченные',
                            'Выполненные',
                          ])
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: ChoiceChip(
                                label: Text(f),
                                selected: filter == f,
                                onSelected: (_) => setState(() => filter = f),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: visible.isEmpty
                          ? const Center(
                              child: Text(
                                'Задач нет. Создайте проект и добавьте задачу.',
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 90),
                              itemCount: visible.length,
                              itemBuilder: (_, index) {
                                final t = visible[index];
                                final conflict = c.data.conflicted(
                                  'task',
                                  t['id'],
                                );
                                final overdue =
                                    t['done'] != true &&
                                    t['due'] != null &&
                                    DateTime.parse(t['due']).isBefore(now);
                                final checklist = t['checklist'] as List;
                                final pname = t['inbox'] == true
                                    ? 'Из почты — выберите проект'
                                    : tree.byId.containsKey(t['projectId'])
                                    ? tree.path(t['projectId'])
                                    : 'Проект недоступен (проверьте конфликты)';
                                final attachments =
                                    (t['attachments'] as List?) ?? const [];
                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: ColorStripe(
                                    colorKey: t['color'],
                                    child: Column(
                                      children: [
                                        ListTile(
                                          leading: Checkbox(
                                            value: t['done'],
                                            onChanged: c.busy || conflict
                                                ? null
                                                : (_) => c.complete(t),
                                          ),
                                          title: Text(
                                            t['title'],
                                            style: TextStyle(
                                              decoration: t['done'] == true
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                            ),
                                          ),
                                          subtitle: Text(
                                            [
                                              '$pname${t['priority'] == 2 ? ' • Высокий приоритет' : ''}',
                                              if (t['due'] != null)
                                                'Срок: ${dateLabel(t['due'])}',
                                              if (t['reminder'] != null)
                                                'Напомнить: ${dateLabel(t['reminder'])}',
                                              if (t['repeat'] != 'none')
                                                repeatNames[t['repeat']]!,
                                              if (t['notes'].isNotEmpty)
                                                t['notes'],
                                              if (checklist.isNotEmpty)
                                                'Чек-лист: ${checklist.where((x) => x['done'] == true).length}/${checklist.length}',
                                              if (attachments.isNotEmpty)
                                                'Вложений: ${attachments.length}',
                                              if (dueMoves(t) > 0)
                                                'Срок переносился: ${dueMoves(t)}',
                                              'Оценка: ${estimateLabel(estimateOf(t))}',
                                              if (involvedNames(
                                                c.data,
                                                t,
                                              ).isNotEmpty)
                                                'Задействованы: ${involvedNames(c.data, t, short: true).join(', ')}',
                                              if (workLabel(t) != null)
                                                workLabel(t)!,
                                              if (!onTimeline(t))
                                                'Не на временной шкале',
                                              if (conflict)
                                                'Конфликт: редактирование временно заблокировано',
                                            ].join('\n'),
                                            style: TextStyle(
                                              color: overdue
                                                  ? Theme.of(
                                                      context,
                                                    ).colorScheme.error
                                                  : null,
                                            ),
                                          ),
                                          isThreeLine: true,
                                          onTap: c.busy || conflict
                                              ? null
                                              : () => edit(t),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (t['startedAt'] == null &&
                                                  t['done'] != true)
                                                IconButton(
                                                  tooltip: 'Начать выполнение',
                                                  onPressed: c.busy || conflict
                                                      ? null
                                                      : () => c.start(t),
                                                  icon: const Icon(
                                                    Icons.play_circle_outline,
                                                  ),
                                                ),
                                              IconButton(
                                                tooltip: 'Удалить задачу',
                                                onPressed: c.busy || conflict
                                                    ? null
                                                    : () async {
                                                        if (await confirm(
                                                          context,
                                                          'Удалить задачу?',
                                                          t['title'],
                                                          action: 'Удалить',
                                                        )) {
                                                          await c.save(
                                                            'task',
                                                            t,
                                                            deleted: true,
                                                          );
                                                        }
                                                      },
                                                icon: const Icon(
                                                  Icons.delete_outline,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (checklist.isNotEmpty)
                                          ExpansionTile(
                                            title: const Text(
                                              'Пункты чек-листа',
                                            ),
                                            children: [
                                              for (final item in checklist)
                                                CheckboxListTile(
                                                  tileColor: rowTint(
                                                    context,
                                                    item['color'],
                                                  ),
                                                  secondary:
                                                      rowColor(item['color']) ==
                                                          null
                                                      ? null
                                                      : Icon(
                                                          Icons.circle,
                                                          size: 12,
                                                          color: rowColor(
                                                            item['color'],
                                                          ),
                                                        ),
                                                  title: Text(item['text']),
                                                  value: item['done'],
                                                  onChanged:
                                                      c.busy ||
                                                          conflict ||
                                                          t['done'] == true
                                                      ? null
                                                      : (v) {
                                                          final updated = clone(
                                                            t,
                                                          );
                                                          for (final x
                                                              in updated['checklist']) {
                                                            if (x['id'] ==
                                                                item['id']) {
                                                              x['done'] = v;
                                                            }
                                                          }
                                                          c.save(
                                                            'task',
                                                            updated,
                                                          );
                                                        },
                                                ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: !c.ready || c.fatal != null
          ? null
          : NavigationBar(
              selectedIndex: tab,
              height: 64,
              onDestinationSelected: (v) => setState(() => tab = v),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.checklist_outlined),
                  selectedIcon: Icon(Icons.checklist),
                  label: 'Задачи',
                ),
                NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined),
                  selectedIcon: Icon(Icons.menu_book),
                  label: 'База знаний',
                ),
                NavigationDestination(
                  icon: Icon(Icons.shopping_cart_outlined),
                  selectedIcon: Icon(Icons.shopping_cart),
                  label: 'Покупки',
                ),
              ],
            ),
      floatingActionButton: !c.ready || c.busy
          ? null
          : FloatingActionButton.extended(
              onPressed: tab == 0
                  ? edit
                  : tab == 1
                  ? () => knowledge.currentState?.open()
                  : () => shopping.currentState?.open(),
              icon: const Icon(Icons.add),
              label: Text(
                tab == 0
                    ? 'Задача'
                    : tab == 1
                    ? 'Запись'
                    : 'Список',
              ),
            ),
    );
  }

  Widget _notice(String text, IconData icon) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

List<DropdownMenuItem<String>> projectItems(
  ProjectTree tree, {
  Set<String> exclude = const {},
}) => [
  for (final e in tree.flatten())
    if (!exclude.contains(e.project['id']))
      DropdownMenuItem<String>(
        value: e.project['id'],
        child: Padding(
          padding: EdgeInsets.only(left: 16.0 * e.depth),
          child: Text(
            '${e.depth > 0 ? '└ ' : ''}${e.project['name']}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
];

class ProjectEditor extends StatefulWidget {
  final List<Json> projects;
  final Json? old;
  final String? parentId;
  const ProjectEditor({
    super.key,
    required this.projects,
    this.old,
    this.parentId,
  });
  @override
  State<ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends State<ProjectEditor> {
  late final name = TextEditingController(text: widget.old?['name'] ?? '');
  late final tree = ProjectTree(widget.projects);
  // A project cannot be moved into itself or into its own subproject.
  late final exclude = widget.old == null
      ? <String>{}
      : tree.subtree(widget.old!['id']);
  late String parent =
      widget.parentId != null &&
          tree.byId.containsKey(widget.parentId) &&
          !exclude.contains(widget.parentId)
      ? widget.parentId!
      : '';
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void submit() {
    if (name.text.trim().isEmpty) return;
    Navigator.pop(context, <String, dynamic>{
      ...?widget.old,
      'id': widget.old?['id'] ?? uuid.v4(),
      'name': name.text.trim(),
      'parentId': parent.isEmpty ? null : parent,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.old == null ? 'Новый проект' : 'Изменить проект'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Название'),
            onSubmitted: (_) => submit(),
          ),
          DropdownButtonFormField<String>(
            initialValue: parent,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Входит в проект'),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('— Верхний уровень —'),
              ),
              ...projectItems(tree, exclude: exclude),
            ],
            onChanged: (v) => setState(() => parent = v!),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: submit, child: const Text('Сохранить')),
    ],
  );
}

class TaskEditor extends StatefulWidget {
  final AppController controller;
  final List<Json> projects;
  final Json? old;
  final String projectId;
  const TaskEditor({
    super.key,
    required this.controller,
    required this.projects,
    this.old,
    required this.projectId,
  });
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final TextEditingController title = TextEditingController(
    text: widget.old?['title'] ?? '',
  );

  /// Due time minus the estimate (see startBeforeDue), or null.
  String? calcStart() => due == null
      ? null
      : startBeforeDue(
          DateTime.parse(due!).toLocal(),
          estimate,
          widget.controller.workSchedule,
        ).toUtc().toIso8601String();
  late final RichTextController notes = RichTextController(
    text: widget.old?['notes'] ?? '',
    format: widget.old?['notesFmt'],
  );
  late final checklistCtl = ChecklistController(widget.old?['checklist']);
  late String? color = widget.old?['color'];
  late final bool inbox = widget.old?['inbox'] == true;
  late String pid =
      widget.projects.any((p) => p['id'] == widget.old?['projectId'])
      ? widget.old!['projectId']
      : inbox
      ? ''
      : widget.projectId;
  late int priority = widget.old?['priority'] ?? 1;
  late String? due = widget.old?['due'];
  late String? startedAt = widget.old?['startedAt'];
  late int estimate = estimateOf(widget.old ?? const {});
  late bool timeline = widget.old?['timeline'] != false;
  late List<String> people = [
    for (final id in (widget.old?['people'] as List?) ?? const []) id as String,
  ];
  late String? finishedAt = widget.old?['finishedAt'];
  late String? reminder = widget.old?['reminder'];
  late String repeat = widget.old?['repeat'] ?? 'none';
  List<Json> get checklist => checklistCtl.items;
  late List<Json> attachments = [
    for (final a in widget.old?['attachments'] ?? []) clone(a),
  ];
  late final List history = (widget.old?['dueHistory'] as List?) ?? const [];
  final reason = TextEditingController();
  late final tree = ProjectTree(widget.projects);
  bool get dueChanged =>
      widget.old != null &&
      withDueHistory(widget.old, {'due': due})['dueHistory'].length !=
          history.length;
  bool importing = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    notes.dispose();
    checklistCtl.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<String?> pick(String? old) async {
    final initial = old == null
        ? DateTime.now()
        : DateTime.parse(old).toLocal();
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2200),
    );
    if (day == null || !mounted) return old;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return old;
    return DateTime(
      day.year,
      day.month,
      day.day,
      time.hour,
      time.minute,
    ).toUtc().toIso8601String();
  }

  void save() {
    if (title.text.trim().isEmpty) {
      setState(() => error = 'Введите название задачи');
      return;
    }
    if (repeat != 'none' && due == null) {
      setState(() => error = 'Укажите срок для повторяющейся задачи');
      return;
    }
    if (pid.isEmpty) {
      setState(() => error = 'Выберите проект');
      return;
    }
    if (estimate <= 0) {
      setState(() => error = 'Укажите предполагаемое время на выполнение');
      return;
    }
    if (startedAt != null &&
        finishedAt != null &&
        DateTime.parse(finishedAt!).isBefore(DateTime.parse(startedAt!))) {
      setState(() => error = 'Окончание выполнения раньше начала');
      return;
    }
    checklistCtl.addPending();
    Navigator.pop(
      context,
      withDueHistory(widget.old, reason: reason.text, <String, dynamic>{
        'id': widget.old?['id'] ?? uuid.v4(),
        'title': title.text.trim(),
        'notes': notes.text.trim(),
        'notesFmt': notes.trimmedFormat,
        'projectId': pid,
        'priority': priority,
        'done': widget.old?['done'] ?? false,
        'due': due,
        'startedAt': startedAt,
        'finishedAt': finishedAt,
        'estimate': estimate,
        'people': people,
        'timeline': timeline,
        'reminder': reminder,
        'repeat': repeat,
        'checklist': checklist,
        'attachments': attachments,
        if (color != null) 'color': color,
        if (widget.old?['source'] != null) 'source': widget.old!['source'],
        'repeatDay':
            due == (widget.old?['due']) && repeat == (widget.old?['repeat'])
            ? (widget.old?['repeatDay'])
            : due == null
            ? null
            : DateTime.parse(due!).toLocal().day,
      }),
    );
  }

  /// Imports files into the local store and adds them to this task.
  Future<void> addFiles(Future<List<PickedFile>> Function() source) async {
    setState(() {
      importing = true;
      error = null;
    });
    try {
      final picked = await source();
      for (final f in picked) {
        final meta = await widget.controller.files.import(
          f.path,
          name: f.name,
          kind: f.kind,
        );
        if (!mounted) return;
        setState(() => attachments.add(meta));
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось добавить файл: $e');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.old == null
          ? 'Новая задача'
          : inbox
          ? 'Задача из почты'
          : 'Изменить задачу',
    ),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Название задачи'),
            ),
            DropdownButtonFormField<String>(
              initialValue: pid,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Проект',
                helperText: inbox && pid.isEmpty
                    ? 'Письмо из почты: выберите проект, срок и приоритет'
                    : null,
              ),
              items: [
                if (pid.isEmpty)
                  const DropdownMenuItem(
                    value: '',
                    child: Text('— выберите проект —'),
                  ),
                ...projectItems(tree),
              ],
              onChanged: (v) => setState(() => pid = v!),
            ),
            DropdownButtonFormField<int>(
              initialValue: priority,
              decoration: const InputDecoration(labelText: 'Приоритет'),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Низкий')),
                DropdownMenuItem(value: 1, child: Text('Обычный')),
                DropdownMenuItem(value: 2, child: Text('Высокий')),
              ],
              onChanged: (v) => setState(() => priority = v!),
            ),
            const SizedBox(height: 8),
            RichToolbar(controller: notes),
            TextField(
              key: const ValueKey('task-notes'),
              controller: notes,
              minLines: 2,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Заметки'),
            ),
            const SizedBox(height: 16),
            Text('Срок: ${dateLabel(due)}'),
            Wrap(
              children: [
                TextButton(
                  onPressed: () async {
                    final v = await pick(due);
                    if (mounted) setState(() => due = v);
                  },
                  child: const Text('Указать срок'),
                ),
                TextButton(
                  onPressed: () => setState(() => due = null),
                  child: const Text('Убрать срок'),
                ),
              ],
            ),
            if (dueChanged)
              TextField(
                controller: reason,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: 'Причина изменения срока (необязательно)',
                  helperText: widget.old?['due'] == null
                      ? null
                      : 'Было: ${dateLabel(widget.old!['due'])}',
                ),
              ),
            if (history.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                leading: const Icon(Icons.history),
                title: Text('История сроков (${history.length})'),
                subtitle: dueMoves(widget.old!) > 0
                    ? Text('Переносов: ${dueMoves(widget.old!)}')
                    : null,
                children: [
                  for (final h in history.reversed)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(dueChangeLabel(h)),
                      subtitle: Text(
                        'Изменено ${dateLabel(h['at'])}'
                        '${h['reason'] == null ? '' : '\nПричина: ${h['reason']}'}',
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            PeopleField(
              controller: widget.controller,
              selected: people,
              onChanged: (v) => setState(() => people = v),
            ),
            const SizedBox(height: 12),
            EstimateField(
              minutes: estimate,
              onChanged: (v) => setState(() => estimate = v),
            ),
            CheckboxListTile(
              key: const ValueKey('timeline-check'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: timeline,
              onChanged: (v) => setState(() => timeline = v!),
              title: const Text('Показывать на временной шкале'),
              subtitle: const Text(
                'Если снять, задача не попадает в шкалу дня, загрузку '
                'календаря и планирование',
              ),
            ),
            const SizedBox(height: 12),
            WorkTimeEditor(
              startedAt: startedAt,
              finishedAt: finishedAt,
              pick: pick,
              calcStart: calcStart,
              onChanged: (s, f) => setState(() {
                startedAt = s;
                finishedAt = f;
              }),
            ),
            const SizedBox(height: 8),
            Text('Напоминание: ${dateLabel(reminder)}'),
            Wrap(
              children: [
                TextButton(
                  onPressed: () async {
                    final v = await pick(reminder);
                    if (mounted) setState(() => reminder = v);
                  },
                  child: const Text('Указать время'),
                ),
                TextButton(
                  onPressed: due == null
                      ? null
                      : () => setState(
                          () => reminder = DateTime.parse(due!)
                              .subtract(const Duration(hours: 1))
                              .toUtc()
                              .toIso8601String(),
                        ),
                  child: const Text('За час до срока'),
                ),
                Tooltip(
                  message: 'Срок минус предполагаемое время',
                  child: TextButton(
                    key: const ValueKey('calc-reminder'),
                    onPressed: due == null
                        ? null
                        : () => setState(() => reminder = calcStart()),
                    child: const Text('Рассчитать'),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => reminder = null),
                  child: const Text('Выключить'),
                ),
              ],
            ),
            if (reminder != null &&
                !DateTime.parse(reminder!).isAfter(DateTime.now()))
              const Text(
                'Время уже прошло. Новое уведомление не будет запланировано.',
              ),
            DropdownButtonFormField<String>(
              initialValue: repeat,
              decoration: const InputDecoration(labelText: 'Повторение'),
              items: repeatNames.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: (v) => setState(() => repeat = v!),
            ),
            if (repeat != 'none')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Следующий экземпляр создаётся после выполнения текущего. '
                  'Старый сохраняется в выполненных.',
                ),
              ),
            const SizedBox(height: 16),
            ChecklistEditor(controller: checklistCtl),
            const SizedBox(height: 12),
            ColorPicker(
              value: color,
              onChanged: (k) => setState(() => color = k),
            ),
            const SizedBox(height: 16),
            AttachmentsSection(
              controller: widget.controller,
              attachments: attachments,
              busy: importing,
              onAdd: addFiles,
              onRemove: (a) => setState(() => attachments.remove(a)),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: importing
            ? null
            : () {
                if (checklist.any(
                  (c) => (c['text'] as String).trim().isEmpty,
                )) {
                  setState(
                    () => error = 'Пункт чек-листа не может быть пустым',
                  );
                  return;
                }
                save();
              },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

class SettingsPage extends StatefulWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppController get c => widget.controller;
  late String provider = c.prefs.getString('provider') ?? 'none';
  late String theme = c.prefs.getString('theme') ?? 'system';
  late String color = c.prefs.getString('color') ?? 'Индиго';
  late bool msix = c.prefs.getBool('windows_msix_confirmed') ?? false;
  late bool autoSync = c.autoSync;
  late int interval = c.syncInterval;
  final email = TextEditingController();
  final password = TextEditingController();
  final secret = TextEditingController();
  late final desktop = TextEditingController(
    text: c.prefs.getString('google_desktop_client') ?? '',
  );
  late final android = TextEditingController(
    text: c.prefs.getString('google_android_server_client') ?? '',
  );
  String status = '';
  bool credentialsReady = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await vault.read(key: 'mail_email');
      if (mounted) {
        setState(() {
          email.text = value ?? '';
          credentialsReady = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => status =
              'Не удалось открыть защищённое хранилище. Облачные настройки не будут изменены.',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final t in [email, password, secret, desktop, android]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (!credentialsReady) {
      setState(
        () =>
            status = 'Защищённое хранилище недоступно. Настройки не сохранены.',
      );
      return;
    }
    final ok = await c.run(() async {
      if (provider == 'mail' && !email.text.contains('@')) {
        throw StateError('Укажите полный адрес почты Mail');
      }
      final savedEmail = await vault.read(key: 'mail_email') ?? '';
      if (provider == 'mail' &&
          savedEmail != email.text.trim() &&
          password.text.isEmpty) {
        throw StateError(
          'Для другого аккаунта введите новый пароль приложения',
        );
      }
      await vault.write(key: 'mail_email', value: email.text.trim());
      if (password.text.isNotEmpty) {
        await vault.write(key: 'mail_password', value: password.text);
      }
      if (secret.text.isNotEmpty) {
        await vault.write(
          key: 'google_desktop_secret',
          value: secret.text.trim(),
        );
      }
      if (desktop.text.trim() !=
          (c.prefs.getString('google_desktop_client') ?? '')) {
        await vault.delete(key: 'google_refresh');
        if (secret.text.isEmpty) {
          await vault.delete(key: 'google_desktop_secret');
        }
      }
      for (final e in {
        'provider': provider,
        'theme': theme,
        'color': color,
        'google_desktop_client': desktop.text.trim(),
        'google_android_server_client': android.text.trim(),
      }.entries) {
        if (!await c.prefs.setString(e.key, e.value)) {
          throw StateError('Не сохранены настройки');
        }
      }
      if (!await c.prefs.setBool('windows_msix_confirmed', msix) ||
          !await c.prefs.setBool('auto_sync', autoSync) ||
          !await c.prefs.setInt('sync_interval', interval)) {
        throw StateError('Ошибка сохранения настроек');
      }
      c.configureAutoSync();
      password.clear();
      secret.clear();
      await c.schedule();
    });
    if (mounted) {
      setState(
        () => status = ok ? 'Настройки сохранены.' : c.message ?? 'Ошибка',
      );
    }
  }

  Future<void> export() async {
    await c.run(() async {
      final bytes = Uint8List.fromList(utf8.encode(c.data.encode()));
      final location = await FilePicker.platform.saveFile(
        dialogTitle: 'Экспорт резервной копии',
        fileName:
            'project_reminders_backup_${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (location == null) return;
      if (mounted) {
        setState(
          () => status =
              'Копия экспортирована. Она содержит задачи, но не пароли.',
        );
      }
    });
  }

  Future<void> restore() async {
    await c.run(() async {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'JSON',
            extensions: ['json'],
            mimeTypes: ['application/json'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 10 * 1024 * 1024) {
        throw const FormatException('Файл больше 10 МБ');
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      final backup = decoded is Map && decoded['version'] == 1
          ? Dataset.migrate(raw)
          : Dataset.decode(raw);
      if (!mounted) return;
      final yes = await confirm(
        context,
        'Восстановить резервную копию?',
        'В копии проектов: ${backup.visible("project").length}, задач: ${backup.visible("task").length}. '
            'Текущий набор будет заменён. Перед заменой сохранится автоматическая копия. '
            'Изменения попадут в облако при следующей синхронизации. '
            'Вложения в JSON не входят — только ссылки на них.',
        action: 'Восстановить',
      );
      if (!yes) return;
      await c.locked(() async {
        await c.repository.backup(c.data);
        await c.persist(c.repository.restore(c.data, backup, c.device));
      });
      if (mounted) {
        setState(
          () => status = c.autoSync && c.provider != 'none'
              ? 'Копия восстановлена и будет отправлена в облако.'
              : 'Копия восстановлена. Облако ещё не изменено.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (_, _) => Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (c.busy) const LinearProgressIndicator(),
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(status),
                ),
              if (c.message != null) Text(c.message!),
              _heading('Оформление'),
              DropdownButtonFormField<String>(
                initialValue: theme,
                decoration: const InputDecoration(labelText: 'Тема'),
                items: const [
                  DropdownMenuItem(
                    value: 'system',
                    child: Text('Как в системе'),
                  ),
                  DropdownMenuItem(value: 'light', child: Text('Светлая')),
                  DropdownMenuItem(value: 'dark', child: Text('Тёмная')),
                ],
                onChanged: c.busy ? null : (v) => setState(() => theme = v!),
              ),
              DropdownButtonFormField<String>(
                initialValue: color,
                decoration: const InputDecoration(labelText: 'Основной цвет'),
                items: colors.keys
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: c.busy ? null : (v) => setState(() => color = v!),
              ),
              _heading('Системные напоминания'),
              const Text(
                'Время напоминания задаётся отдельно от срока задачи. '
                'Оно хранится как конкретный момент времени. После смены часового пояса проверьте расписание.',
              ),
              if (Platform.isWindows)
                CheckboxListTile(
                  title: const Text('Включить напоминания Windows'),
                  subtitle: const Text(
                    'Наличие MSIX проверяется автоматически. В обычном EXE расписание отключено.',
                  ),
                  value: msix,
                  onChanged: c.busy ? null : (v) => setState(() => msix = v!),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: c.busy
                        ? null
                        : () async {
                            await c.run(() async {
                              final text = await c.reminders.permissions();
                              await c.schedule();
                              if (mounted) setState(() => status = text);
                            });
                          },
                    child: const Text('Разрешения и проверка'),
                  ),
                  OutlinedButton(
                    onPressed: c.busy
                        ? null
                        : () async {
                            await c.run(() async {
                              await c.reminders.test();
                              if (mounted) {
                                setState(
                                  () => status =
                                      'Тест запланирован через 30 секунд. Сверните приложение.',
                                );
                              }
                            });
                          },
                    child: const Text('Тест через 30 секунд'),
                  ),
                ],
              ),
              if (c.warning != null) Text(c.warning!),
              _heading('Облако'),
              const Text(
                'Один активный сервис. Синхронизация выполняется автоматически: '
                'при запуске, через 10 секунд после изменений, при возврате в приложение '
                'и по расписанию. Кнопка с облаком на главном экране запускает обмен сразу. '
                'Вложения (голос, фото, видео, файлы) отправляются отдельными файлами; '
                'на другом устройстве они скачиваются при первом открытии.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Автоматическая синхронизация'),
                subtitle: const Text(
                  'Пока приложение открыто. При закрытом приложении обмена нет.',
                ),
                value: autoSync,
                onChanged: c.busy ? null : (v) => setState(() => autoSync = v),
              ),
              if (autoSync)
                DropdownButtonFormField<int>(
                  initialValue: syncIntervals.containsKey(interval)
                      ? interval
                      : 15,
                  decoration: const InputDecoration(
                    labelText: 'Дополнительно проверять облако',
                  ),
                  items: syncIntervals.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: c.busy
                      ? null
                      : (v) => setState(() => interval = v!),
                ),
              if (c.provider != 'none')
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: c.busy || c.syncing
                        ? null
                        : () async {
                            await c.resendAttachments();
                            if (mounted) {
                              setState(
                                () => status = c.syncError == null
                                    ? 'Вложения проверены и отправлены в облако.'
                                    : 'Ошибка: ${c.syncError}',
                              );
                            }
                          },
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Отправить все вложения заново'),
                  ),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.people_outline),
                title: const Text('Справочник ФИО'),
                subtitle: Text('Людей: ${c.data.visible('person').length}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PeoplePage(controller: c),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: const Text('Рабочее время'),
                subtitle: Text(() {
                  final w = c.workSchedule;
                  return '${hm(w.start)}–${hm(w.end)}'
                      '${w.hasBreak ? ', перерыв ${hm(w.breakStart)}–${hm(w.breakEnd)}' : ''}';
                }()),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkTimePage(controller: c),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.forward_to_inbox),
                title: const Text('Задачи из почты'),
                subtitle: Text(
                  c.intakeEnabled
                      ? 'Включено на этом устройстве: ${c.prefs.getString('intake_user') ?? ''}'
                      : 'Пересылайте письма на отдельный ящик — программа создаст задачи',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MailIntakePage(controller: c),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: provider,
                decoration: const InputDecoration(labelText: 'Сервис'),
                items: const [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text('Только на устройстве'),
                  ),
                  DropdownMenuItem(value: 'mail', child: Text('Облако Mail')),
                  DropdownMenuItem(value: 'google', child: Text('Google Диск')),
                ],
                onChanged: c.busy ? null : (v) => setState(() => provider = v!),
              ),
              if (provider == 'mail') ...[
                TextField(
                  controller: email,
                  enabled: !c.busy && credentialsReady,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Адрес почты Mail',
                  ),
                ),
                TextField(
                  controller: password,
                  enabled: !c.busy && credentialsReady,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Пароль внешнего приложения',
                    helperText: 'Пустое поле сохраняет ранее введённый пароль',
                  ),
                ),
                const Text(
                  'WebDAV: webdav.cloud.mail.ru, папка ProjectReminders-v2. '
                  'Не используйте основной пароль почты.',
                ),
              ],
              if (provider == 'google') ...[
                const Text(
                  'OAuth настраивается один раз в Google Cloud. Клиенты Windows и Android '
                  'должны принадлежать одному проекту. Подключение Диска к чату не подключает приложение.',
                ),
                TextField(
                  controller: desktop,
                  enabled: !c.busy,
                  decoration: const InputDecoration(
                    labelText: 'Windows: Desktop OAuth Client ID',
                  ),
                ),
                TextField(
                  controller: secret,
                  enabled: !c.busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Windows: Desktop Client Secret',
                    helperText:
                        'Из Desktop OAuth credentials; пусто = оставить прежний',
                  ),
                ),
                TextField(
                  controller: android,
                  enabled: !c.busy,
                  decoration: const InputDecoration(
                    labelText: 'Android: Web OAuth Client ID (serverClientId)',
                  ),
                ),
                const Text(
                  'Первый вход — кнопкой синхронизации на главном экране; дальше '
                  'обмен идёт автоматически без входа. Данные сохраняются '
                  'в скрытой папке приложения; обычные файлы Диска не читаются.',
                ),
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () async {
                          await c.run(() async {
                            await c.google.disconnect();
                            if (mounted) {
                              setState(
                                () => status =
                                    'Локальный вход Google сброшен. Данные облака не удалены.',
                              );
                            }
                          });
                        },
                  child: const Text('Сбросить вход Google на этом устройстве'),
                ),
              ],
              if (provider != 'none')
                Text(
                  'Последний обмен: ${c.prefs.getString("last_sync_$provider") ?? "ещё не выполнен"}',
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: c.busy || !credentialsReady ? null : save,
                child: const Text('Сохранить настройки'),
              ),
              _heading('Резервные копии'),
              const Text(
                'Перед изменениями сохраняются до 30 локальных копий. '
                'Это не защита от потери устройства: экспортируйте копии отдельно. '
                'JSON не зашифрован и содержит названия и заметки задач.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: c.busy ? null : export,
                    child: const Text('Экспорт JSON'),
                  ),
                  OutlinedButton(
                    onPressed: c.busy ? null : restore,
                    child: const Text('Восстановить из JSON'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                'Папка данных:\n${c.repository.directory.path}\n'
                'Автокопии:\n${c.repository.backups.path}',
              ),
              _heading('О версии'),
              const Text(
                '1.3.3 • Один пользователь • Windows / Android\n'
                'Шкала времени дня в календаре занятости.\n'
                'Вкладка «Покупки»: списки по датам и магазинам, списки из почты.\n'
                'Справочник ФИО и задействованные в задачах и записях.\n'
                'Календарь занятости, планирование, рабочее время, оценка задач, Excel на почту, обновления из облака.\n'
                'Время начала и окончания выполнения задач.\n'
                'Задачи из почты, чек-листы в базе знаний, цвета строк.\n'
                'История сроков задач, база знаний с рисованием.\n'
                'Автосинхронизация, дерево подпроектов, вложения в задачах.\n'
                'Повторные задачи создаются при выполнении. Если срок давно прошёл, '
                'следующий экземпляр тоже может быть просрочен. '
                'При повторном открытии выполненной задачи уже созданный следующий экземпляр остаётся.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 10),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
}

class ConflictsPage extends StatelessWidget {
  final AppController controller;
  const ConflictsPage({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => Scaffold(
      appBar: AppBar(title: const Text('Конфликтующие версии')),
      body: controller.data.conflicts.isEmpty
          ? const Center(child: Text('Конфликтов нет'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Ни одна параллельная правка не удалена автоматически. '
                  'Показана информация обеих версий; выбор заменит остальные версии этой записи. '
                  'Перед выбором автоматически создаётся резервная копия.',
                ),
                for (final key in controller.data.conflicts)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            key,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          for (final version
                              in controller.data.records[key]!) ...[
                            const Divider(),
                            Text(
                              '${version['deleted'] == true ? 'Удалено' : 'Сохранено'} • '
                              '${dateLabel(version['updatedAt'])}',
                            ),
                            SelectableText(
                              const JsonEncoder.withIndent(
                                '  ',
                              ).convert(version['data']),
                            ),
                            OutlinedButton(
                              onPressed: controller.busy
                                  ? null
                                  : () async {
                                      if (await confirm(
                                        context,
                                        'Выбрать эту версию?',
                                        'Другие версии данной записи будут заменены. Автокопия останется.',
                                      )) {
                                        await controller.resolve(key, version);
                                      }
                                    },
                              child: const Text('Использовать эту версию'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    ),
  );
}
