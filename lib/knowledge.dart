import 'package:flutter/material.dart';

import 'attachments_ui.dart';
import 'controller.dart';
import 'domain.dart';
import 'row_ui.dart';
import 'people.dart';
import 'rich_text.dart';

/// Knowledge base: a tree of named entries. Each entry holds text and
/// attachments (voice, photo, video, drawings, any files).
class KnowledgeView extends StatefulWidget {
  final AppController controller;
  const KnowledgeView({super.key, required this.controller});
  @override
  State<KnowledgeView> createState() => KnowledgeViewState();
}

class KnowledgeViewState extends State<KnowledgeView> {
  AppController get c => widget.controller;
  final expanded = <String>{};
  String query = '';

  Future<void> open({Json? note, String? parentId}) async {
    final result = await Navigator.of(context).push<Json>(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          controller: c,
          notes: c.data.visible('note'),
          old: note,
          parentId: parentId,
        ),
      ),
    );
    if (result == null) return;
    if (await c.save('note', result) && result['parentId'] != null) {
      setState(() => expanded.add(result['parentId']));
    }
  }

  Future<void> delete(Json note) async {
    final tree = ProjectTree(c.data.visible('note'), nameKey: 'title');
    final ids = tree.subtree(note['id']);
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text(
          '«${tree.path(note['id'])}»\n'
          '${ids.length > 1 ? 'Вложенных записей: ${ids.length - 1} — они тоже будут удалены. ' : ''}'
          'Удаление попадёт на все устройства после синхронизации. '
          'Перед удалением сохраняется автоматическая копия.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (yes == true) await c.deleteNotes(note['id']);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final notes = c.data.visible('note');
      final tree = ProjectTree(notes, nameKey: 'title');
      final q = query.trim().toLowerCase();
      // While searching, show matches together with their parents.
      Set<String>? shown;
      if (q.isNotEmpty) {
        shown = {};
        for (final n in notes) {
          final names = (n['attachments'] as List? ?? const [])
              .map((a) => a['name'])
              .join(' ');
          final extra = [
            ...((n['checklist'] as List?) ?? const []).map((x) => x['text']),
            ...involvedNames(c.data, n),
          ].join(' ');
          if ('${n['title']} ${n['text'] ?? ''} $names $extra'
              .toLowerCase()
              .contains(q)) {
            String? cur = n['id'];
            while (cur != null && shown.add(cur)) {
              cur = tree.effectiveParent(cur);
            }
          }
        }
      }
      final rows = <({Json note, int depth})>[];
      void walk(Json n, int depth) {
        if (shown != null && !shown.contains(n['id'])) return;
        rows.add((note: n, depth: depth));
        if (shown != null || expanded.contains(n['id'])) {
          for (final ch in tree.children[n['id']] ?? const <Json>[]) {
            walk(ch, depth + 1);
          }
        }
      }

      for (final r in tree.roots) {
        walk(r, 0);
      }
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск по названию, тексту и файлам',
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
          if (q.isEmpty && notes.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() {
                  if (expanded.isEmpty) {
                    expanded.addAll(tree.children.keys);
                  } else {
                    expanded.clear();
                  }
                }),
                child: Text(
                  expanded.isEmpty ? 'Развернуть всё' : 'Свернуть всё',
                ),
              ),
            ),
          Expanded(
            child: notes.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Здесь будет база знаний: инструкции, настройки, '
                        'схемы, фото, видео и голосовые заметки. '
                        'Нажмите «Запись», чтобы добавить первую.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : rows.isEmpty
                ? const Center(child: Text('Ничего не найдено'))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final n = rows[i].note;
                      final id = n['id'] as String;
                      final kids = tree.children[id]?.length ?? 0;
                      final files =
                          (n['attachments'] as List? ?? const []).length;
                      final text = (n['text'] as String? ?? '').trim();
                      final conflicted = c.data.conflicted('note', id);
                      final list = (n['checklist'] as List?) ?? const [];
                      final doneItems = list
                          .where((x) => x['done'] == true)
                          .length;
                      return ColorStripe(
                        colorKey: n['color'],
                        child: ListTile(
                          contentPadding: EdgeInsets.only(
                            left: 8.0 + 20.0 * rows[i].depth.clamp(0, 8),
                            right: 4,
                          ),
                          leading: kids == 0
                              ? const SizedBox(
                                  width: 40,
                                  child: Icon(Icons.article_outlined),
                                )
                              : IconButton(
                                  tooltip: expanded.contains(id)
                                      ? 'Свернуть'
                                      : 'Развернуть',
                                  onPressed: q.isNotEmpty
                                      ? null
                                      : () => setState(
                                          () => expanded.contains(id)
                                              ? expanded.remove(id)
                                              : expanded.add(id),
                                        ),
                                  icon: Icon(
                                    shown != null || expanded.contains(id)
                                        ? Icons.expand_more
                                        : Icons.chevron_right,
                                  ),
                                ),
                          title: Text(
                            n['title'],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (conflicted) 'Конфликт версий',
                              if (kids > 0) 'Разделов: $kids',
                              if (files > 0) 'Файлов: $files',
                              if (list.isNotEmpty)
                                'Чек-лист: $doneItems/${list.length}',
                              if (involvedNames(c.data, n).isNotEmpty)
                                involvedNames(
                                  c.data,
                                  n,
                                  short: true,
                                ).join(', '),
                              if (text.isNotEmpty) text.split('\n').first,
                            ].join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: c.busy || conflicted
                              ? null
                              : () => open(note: n),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Действия',
                            enabled: !c.busy && !conflicted,
                            onSelected: (v) {
                              if (v == 'child') open(parentId: id);
                              if (v == 'edit') open(note: n);
                              if (v == 'delete') delete(n);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'child',
                                child: Text('Добавить вложенную запись'),
                              ),
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Открыть'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Удалить с вложенными'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
}

class NoteEditorPage extends StatefulWidget {
  final AppController controller;
  final List<Json> notes;
  final Json? old;
  final String? parentId;
  const NoteEditorPage({
    super.key,
    required this.controller,
    required this.notes,
    this.old,
    this.parentId,
  });
  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final title = TextEditingController(text: widget.old?['title'] ?? '');
  late final text = RichTextController(
    text: widget.old?['text'] ?? '',
    format: widget.old?['textFmt'],
  );
  late final tree = ProjectTree(widget.notes, nameKey: 'title');
  late final exclude = widget.old == null
      ? <String>{}
      : tree.subtree(widget.old!['id']);
  late String parent = () {
    final v = widget.old?['parentId'] ?? widget.parentId;
    return v != null && tree.byId.containsKey(v) && !exclude.contains(v)
        ? v as String
        : '';
  }();
  late List<Json> attachments = [
    for (final a in widget.old?['attachments'] ?? []) clone(a),
  ];
  late final checklistCtl = ChecklistController(widget.old?['checklist']);
  late String? color = widget.old?['color'];
  late List<String> people = [
    for (final id in (widget.old?['people'] as List?) ?? const []) id as String,
  ];
  bool importing = false;
  bool changed = false;
  String? error;

  @override
  void initState() {
    super.initState();
    title.addListener(() => changed = true);
    text.addListener(() => changed = true);
  }

  @override
  void dispose() {
    title.dispose();
    text.dispose();
    checklistCtl.dispose();
    super.dispose();
  }

  void save() {
    if (title.text.trim().isEmpty) {
      setState(() => error = 'Введите название записи');
      return;
    }
    checklistCtl.addPending();
    if (checklistCtl.hasEmptyItems) {
      setState(() => error = 'Заполните или удалите пустые пункты чек-листа');
      return;
    }
    changed = false;
    Navigator.pop(
      context,
      <String, dynamic>{
        ...?widget.old,
        'id': widget.old?['id'] ?? uuid.v4(),
        'title': title.text.trim(),
        'text': text.text,
        'textFmt': text.format,
        'parentId': parent.isEmpty ? null : parent,
        'attachments': attachments,
        'checklist': checklistCtl.items,
        'people': people,
        'color': color,
      }..removeWhere((k, v) => k == 'color' && v == null),
    );
  }

  Future<void> addFiles(Future<List<PickedFile>> Function() source) async {
    setState(() {
      importing = true;
      error = null;
    });
    try {
      for (final f in await source()) {
        final meta = await widget.controller.files.import(
          f.path,
          name: f.name,
          kind: f.kind,
        );
        if (!mounted) return;
        setState(() {
          attachments.add(meta);
          changed = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось добавить файл: $e');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final navigator = Navigator.of(context);
      if (!changed) {
        navigator.pop();
        return;
      }
      final leave = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Выйти без сохранения?'),
          content: const Text('Изменения в записи будут потеряны.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Остаться'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Выйти'),
            ),
          ],
        ),
      );
      if (leave == true) navigator.pop();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.old == null ? 'Новая запись' : 'Запись'),
        actions: [
          TextButton(
            onPressed: importing ? null : save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: title,
                autofocus: widget.old == null,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              DropdownButtonFormField<String>(
                initialValue: parent,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Раздел'),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('— Верхний уровень —'),
                  ),
                  for (final e in tree.flatten())
                    if (!exclude.contains(e.project['id']))
                      DropdownMenuItem<String>(
                        value: e.project['id'],
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: 16.0 * e.depth.clamp(0, 8),
                          ),
                          child: Text(
                            '${e.depth > 0 ? '└ ' : ''}${e.project['title']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                ],
                onChanged: (v) => setState(() {
                  parent = v!;
                  changed = true;
                }),
              ),
              const SizedBox(height: 12),
              RichToolbar(controller: text),
              TextField(
                key: const ValueKey('note-text'),
                controller: text,
                minLines: 8,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  labelText: 'Текст',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              PeopleField(
                controller: widget.controller,
                selected: people,
                onChanged: (v) => setState(() {
                  people = v;
                  changed = true;
                }),
              ),
              const SizedBox(height: 12),
              ChecklistEditor(
                controller: checklistCtl,
                onChanged: () => changed = true,
              ),
              const SizedBox(height: 12),
              ColorPicker(
                value: color,
                onChanged: (k) => setState(() {
                  color = k;
                  changed = true;
                }),
              ),
              const SizedBox(height: 16),
              AttachmentsSection(
                controller: widget.controller,
                attachments: attachments,
                busy: importing,
                onAdd: addFiles,
                onRemove: (a) => setState(() {
                  attachments.remove(a);
                  changed = true;
                }),
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
    ),
  );
}
