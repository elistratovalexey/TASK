import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'controller.dart';
import 'domain.dart';

const _uuid = Uuid();

/// People directory sorted by full name.
List<Json> peopleList(Dataset data) => data.visible('person').toList()
  ..sort(
    (a, b) => (a['name'] as String).toLowerCase().compareTo(
      (b['name'] as String).toLowerCase(),
    ),
  );

Map<String, Json> peopleById(Dataset data) => {
  for (final p in data.visible('person')) p['id'] as String: p,
};

/// "Иванов Иван Иванович" → "Иванов И. И.".
String shortName(String full) {
  final parts = full.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return full.trim();
  return [
    parts.first,
    parts.skip(1).map((p) => '${p.characters.first.toUpperCase()}.').join(' '),
  ].join(' ');
}

/// Names of people of a record (deleted people are skipped).
List<String> involvedNames(Dataset data, Json record, {bool short = false}) {
  final byId = peopleById(data);
  return [
    for (final id in (record['people'] as List?) ?? const [])
      if (byId[id] != null)
        short ? shortName(byId[id]!['name']) : byId[id]!['name'] as String,
  ];
}

String normalizeName(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Chips with selected people and a button opening the picker.
class PeopleField extends StatelessWidget {
  final AppController controller;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  const PeopleField({
    super.key,
    required this.controller,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final byId = peopleById(controller.data);
    final known = selected.where(byId.containsKey).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Задействованные (ФИО): ${known.length}'),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final id in known)
              InputChip(
                label: Text(byId[id]!['name']),
                tooltip: byId[id]!['position'],
                onDeleted: () => onChanged([...selected]..remove(id)),
                deleteButtonTooltipMessage: 'Убрать',
              ),
            ActionChip(
              avatar: const Icon(Icons.person_add_alt, size: 18),
              label: const Text('Выбрать ФИО'),
              onPressed: () async {
                final result = await showDialog<List<String>>(
                  context: context,
                  builder: (_) =>
                      PeoplePicker(controller: controller, selected: known),
                );
                if (result != null) onChanged(result);
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Multi-select from the directory with search; a missing person can be
/// added to the directory right here.
class PeoplePicker extends StatefulWidget {
  final AppController controller;
  final List<String> selected;
  const PeoplePicker({
    super.key,
    required this.controller,
    required this.selected,
  });
  @override
  State<PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends State<PeoplePicker> {
  AppController get c => widget.controller;
  late final List<String> chosen = [...widget.selected];
  final query = TextEditingController();
  String? error;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> addNew() async {
    final name = normalizeName(query.text);
    if (name.isEmpty) return;
    final existing = peopleList(c.data)
        .where((p) => (p['name'] as String).toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (existing != null) {
      setState(() {
        if (!chosen.contains(existing['id'])) chosen.add(existing['id']);
        query.clear();
      });
      return;
    }
    final person = {'id': _uuid.v4(), 'name': name};
    if (await c.save('person', person)) {
      setState(() {
        chosen.add(person['id']!);
        query.clear();
        error = null;
      });
    } else {
      setState(() => error = c.message ?? 'Не сохранено');
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = query.text.trim().toLowerCase();
    final all = peopleList(c.data);
    final shown = all
        .where(
          (p) =>
              q.isEmpty ||
              (p['name'] as String).toLowerCase().contains(q) ||
              ((p['position'] as String?) ?? '').toLowerCase().contains(q),
        )
        .toList();
    final exact = all.any(
      (p) =>
          (p['name'] as String).toLowerCase() ==
          normalizeName(query.text).toLowerCase(),
    );
    return AlertDialog(
      title: Text('Выбор ФИО (${chosen.length})'),
      content: SizedBox(
        width: 460,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: query,
              // On phones the keyboard would cover the list.
              autofocus: Theme.of(context).platform == TargetPlatform.windows,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Поиск или новое ФИО',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (shown.length == 1 && q.isNotEmpty) {
                  setState(() {
                    final id = shown.single['id'] as String;
                    chosen.contains(id) ? chosen.remove(id) : chosen.add(id);
                    query.clear();
                  });
                } else if (!exact) {
                  addNew();
                }
              },
            ),
            if (q.isNotEmpty && !exact)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_add_alt),
                title: Text(
                  'Добавить в справочник: ${normalizeName(query.text)}',
                ),
                onTap: c.busy ? null : addNew,
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Expanded(
              child: all.isEmpty
                  ? const Center(
                      child: Text(
                        'Справочник пуст. Введите ФИО выше и нажмите «Добавить».',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final p in shown)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(p['name']),
                            subtitle:
                                (p['position'] as String?)?.isNotEmpty == true
                                ? Text(p['position'])
                                : null,
                            value: chosen.contains(p['id']),
                            onChanged: (v) => setState(
                              () => v!
                                  ? chosen.add(p['id'])
                                  : chosen.remove(p['id']),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, chosen),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}

/// Settings → people directory: add, edit, delete.
class PeoplePage extends StatefulWidget {
  final AppController controller;
  const PeoplePage({super.key, required this.controller});
  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  AppController get c => widget.controller;

  int uses(String id) => [
    ...c.data.visible('task'),
    ...c.data.visible('note'),
  ].where((r) => ((r['people'] as List?) ?? const []).contains(id)).length;

  Future<void> edit([Json? person]) async {
    final name = TextEditingController(text: person?['name'] ?? '');
    final position = TextEditingController(text: person?['position'] ?? '');
    String? error;
    final result = await showDialog<Json>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(person == null ? 'Новый человек' : 'Изменить'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'ФИО',
                  hintText: 'Иванов Иван Иванович',
                ),
              ),
              TextField(
                controller: position,
                decoration: const InputDecoration(
                  labelText: 'Должность, организация (необязательно)',
                ),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final n = normalizeName(name.text);
                if (n.isEmpty) {
                  setLocal(() => error = 'Введите ФИО');
                  return;
                }
                final duplicate = peopleList(c.data).any(
                  (p) =>
                      p['id'] != person?['id'] &&
                      (p['name'] as String).toLowerCase() == n.toLowerCase(),
                );
                if (duplicate) {
                  setLocal(() => error = 'Такое ФИО уже есть в справочнике');
                  return;
                }
                final pos = position.text.trim();
                Navigator.pop(
                  ctx,
                  {
                    ...?person,
                    'id': person?['id'] ?? _uuid.v4(),
                    'name': n,
                    if (pos.isNotEmpty) 'position': pos else 'position': null,
                  }..removeWhere((k, v) => k == 'position' && v == null),
                );
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    // Controllers are left to the garbage collector: the dialog may still be
    // animating out and using them.
    if (result != null) {
      await c.save('person', result);
      if (mounted) setState(() {});
    }
  }

  Future<void> delete(Json p) async {
    final n = uses(p['id']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить ${p['name']}?'),
        content: Text(
          n == 0
              ? 'Человек не указан ни в одной задаче или записи.'
              : 'Указан в задачах и записях: $n. Там он перестанет отображаться.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await c.save('person', p, deleted: true);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: c, builder: (context, _) => page(context));

  Widget page(BuildContext context) {
    final list = peopleList(c.data);
    return Scaffold(
      appBar: AppBar(title: const Text('Справочник ФИО')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: c.busy ? null : () => edit(),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Добавить'),
      ),
      body: list.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Добавьте людей, которых назначаете на задачи. Справочник '
                  'синхронизируется между устройствами.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                for (final p in list)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        (p['name'] as String).characters.first.toUpperCase(),
                      ),
                    ),
                    title: Text(p['name']),
                    subtitle: Text(
                      [
                        if ((p['position'] as String?)?.isNotEmpty == true)
                          p['position'],
                        'задач и записей: ${uses(p['id'])}',
                      ].join(' • '),
                    ),
                    onTap: () => edit(p),
                    trailing: IconButton(
                      tooltip: 'Удалить',
                      onPressed: c.busy ? null : () => delete(p),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
              ],
            ),
    );
  }
}
