import 'package:flutter/material.dart';
import 'controller.dart';
import 'domain.dart';
import 'shopping_model.dart';

const _weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
String _two(int n) => n.toString().padLeft(2, '0');

String dateTitle(String key, {DateTime? now}) {
  final d = parseDateKey(key);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final diff = d.difference(today).inDays;
  final base =
      '${_weekdays[d.weekday - 1]}, ${_two(d.day)}.${_two(d.month)}.${d.year}';
  return switch (diff) {
    0 => 'Сегодня, $base',
    1 => 'Завтра, $base',
    -1 => 'Вчера, $base',
    _ => base,
  };
}

String itemLabel(Json i) => i['qty'] == null || i['qty'] == ''
    ? i['text']
    : '${i['text']} — ${i['qty']}';

Future<DateTime?> pickDate(BuildContext context, DateTime initial) =>
    showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

/// Shop selector with "add a new shop".
class ShopSelector extends StatelessWidget {
  final AppController controller;
  final String? value;
  final String? hint;
  final ValueChanged<String> onChanged;
  const ShopSelector({
    super.key,
    required this.controller,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  Future<void> addNew(BuildContext context) async {
    final name = TextEditingController(text: hint ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый магазин'),
        content: TextField(
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Название',
            hintText: 'Пятёрочка',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name.text),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (result == null || normalizeText(result).isEmpty) return;
    final id = await controller.addShop(result);
    if (id != null) onChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    final shops = shopsList(controller.data);
    final known = shops.any((s) => s['id'] == value);
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('shop-$value-${shops.length}'),
            initialValue: known ? value : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Магазин',
              prefixIcon: const Icon(Icons.storefront_outlined),
              helperText: shops.isEmpty
                  ? 'Добавьте магазин кнопкой справа'
                  : null,
            ),
            hint: const Text('— выберите магазин —'),
            items: [
              for (final s in shops)
                DropdownMenuItem(
                  value: s['id'] as String,
                  child: Text(s['name'], overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
        IconButton(
          tooltip: 'Новый магазин',
          onPressed: () => addNew(context),
          icon: const Icon(Icons.add_business_outlined),
        ),
      ],
    );
  }
}

/// Picking several saved purchase names at once.
class ProductPicker extends StatefulWidget {
  final List<String> names;
  final Set<String> already;
  const ProductPicker({super.key, required this.names, required this.already});
  @override
  State<ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<ProductPicker> {
  final chosen = <String>[];
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = query.text.trim().toLowerCase();
    final shown = widget.names
        .where((n) => !widget.already.contains(n.toLowerCase()))
        .where((n) => q.isEmpty || n.toLowerCase().contains(q))
        .toList();
    return AlertDialog(
      title: Text('Сохранённые покупки (${chosen.length})'),
      content: SizedBox(
        width: 440,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: query,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Поиск',
              ),
              onChanged: (_) => setState(() {}),
            ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('Нет сохранённых покупок'))
                  : ListView(
                      children: [
                        for (final n in shown)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(n),
                            value: chosen.contains(n),
                            onChanged: (v) => setState(
                              () => v! ? chosen.add(n) : chosen.remove(n),
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
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}

/// Editing the items of a list: check, name, quantity, delete; adding with
/// suggestions from saved purchase names.
class PurchaseItemsEditor extends StatefulWidget {
  final AppController controller;
  final List<Json> items;
  final VoidCallback onChanged;
  final bool showDone;
  const PurchaseItemsEditor({
    super.key,
    required this.controller,
    required this.items,
    required this.onChanged,
    this.showDone = true,
  });
  @override
  State<PurchaseItemsEditor> createState() => PurchaseItemsEditorState();
}

class PurchaseItemsEditorState extends State<PurchaseItemsEditor> {
  TextEditingController? input;
  final qty = TextEditingController();
  FocusNode? focus;

  @override
  void dispose() {
    qty.dispose();
    super.dispose();
  }

  Set<String> get present => {
    for (final i in widget.items) normalizeText(i['text']).toLowerCase(),
  };

  /// Adds the typed item (also called before saving).
  void addPending() {
    final text = normalizeText(input?.text ?? '');
    if (text.isEmpty) return;
    final item = newItem(text, qty: qty.text);
    final merged = mergeItems({'items': widget.items}, [item])['items'] as List;
    widget.items
      ..clear()
      ..addAll(merged.cast<Json>());
    input?.clear();
    qty.clear();
    setState(() {});
    widget.onChanged();
    focus?.requestFocus();
  }

  Future<void> fromSaved() async {
    final names = productNames(widget.controller.data);
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (_) => ProductPicker(names: names, already: present),
    );
    if (chosen == null || chosen.isEmpty) return;
    final merged =
        mergeItems({
              'items': widget.items,
            }, chosen.map((n) => newItem(n)))['items']
            as List;
    widget.items
      ..clear()
      ..addAll(merged.cast<Json>());
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final names = productNames(widget.controller.data);
    final done = widget.items.where((i) => i['done'] == true).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Покупки: $done из ${widget.items.length} куплено'),
        for (var k = 0; k < widget.items.length; k++)
          Row(
            key: ValueKey(widget.items[k]['id']),
            children: [
              if (widget.showDone)
                Checkbox(
                  value: widget.items[k]['done'] == true,
                  onChanged: (v) => setState(() {
                    widget.items[k] = {...widget.items[k], 'done': v};
                    widget.onChanged();
                  }),
                ),
              Expanded(
                flex: 3,
                child: TextFormField(
                  initialValue: widget.items[k]['text'],
                  decoration: const InputDecoration(isDense: true),
                  style: widget.items[k]['done'] == true
                      ? const TextStyle(decoration: TextDecoration.lineThrough)
                      : null,
                  onChanged: (v) {
                    widget.items[k] = {...widget.items[k], 'text': v};
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 76,
                child: TextFormField(
                  initialValue: widget.items[k]['qty'] ?? '',
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'кол-во',
                  ),
                  onChanged: (v) {
                    widget.items[k] =
                        {
                          ...widget.items[k],
                          'qty': v.trim().isEmpty ? null : v.trim(),
                        }..removeWhere(
                          (key, value) => key == 'qty' && value == null,
                        );
                    widget.onChanged();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Удалить покупку',
                onPressed: () => setState(() {
                  widget.items.removeAt(k);
                  widget.onChanged();
                }),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              flex: 3,
              child: RawAutocomplete<String>(
                optionsBuilder: (v) {
                  final q = v.text.trim().toLowerCase();
                  if (q.isEmpty) return const [];
                  final hits = names
                      .where(
                        (n) =>
                            n.toLowerCase().contains(q) &&
                            !present.contains(n.toLowerCase()),
                      )
                      .toList();
                  return [
                    ...hits.where((n) => n.toLowerCase().startsWith(q)),
                    ...hits.where((n) => !n.toLowerCase().startsWith(q)),
                  ].take(8);
                },
                onSelected: (v) {
                  input?.text = v;
                  addPending();
                },
                fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                  input = controller;
                  focus = focusNode;
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Новая покупка',
                      helperText: 'Подсказки из сохранённых',
                    ),
                    onSubmitted: (_) => addPending(),
                  );
                },
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 280,
                        maxWidth: 320,
                      ),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        children: [
                          for (final o in options)
                            ListTile(
                              dense: true,
                              title: Text(o),
                              onTap: () => onSelected(o),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 76,
              child: TextField(
                controller: qty,
                decoration: const InputDecoration(
                  labelText: 'Кол-во',
                  helperText: '',
                ),
                onSubmitted: (_) => addPending(),
              ),
            ),
            IconButton(
              tooltip: 'Добавить покупку',
              onPressed: addPending,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: fromSaved,
          icon: const Icon(Icons.playlist_add),
          label: const Text('Выбрать из сохранённых'),
        ),
      ],
    );
  }
}

/// A list for one date and shop.
class PurchaseListPage extends StatefulWidget {
  final AppController controller;
  final Json? old;
  final String? date;
  final String? shopId;
  const PurchaseListPage({
    super.key,
    required this.controller,
    this.old,
    this.date,
    this.shopId,
  });
  @override
  State<PurchaseListPage> createState() => _PurchaseListPageState();
}

class _PurchaseListPageState extends State<PurchaseListPage> {
  AppController get c => widget.controller;
  late String date =
      widget.old?['date'] ?? widget.date ?? dateKey(DateTime.now());
  late String? shopId = widget.old?['shopId'] ?? widget.shopId;
  late final List<Json> items = [
    for (final i in (widget.old?['items'] as List?) ?? const [])
      Map<String, dynamic>.from(i),
  ];
  late final note = TextEditingController(text: widget.old?['note'] ?? '');
  final editor = GlobalKey<PurchaseItemsEditorState>();
  bool changed = false;
  String? error;

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> save() async {
    editor.currentState?.addPending();
    if (shopId == null || !shopsById(c.data).containsKey(shopId)) {
      setState(() => error = 'Выберите магазин');
      return;
    }
    final clean = [
      for (final i in items)
        if (normalizeText(i['text']).isNotEmpty)
          {...i, 'text': normalizeText(i['text'])},
    ];
    if (clean.isEmpty) {
      setState(() => error = 'Добавьте хотя бы одну покупку');
      return;
    }
    final list = {
      ...?widget.old,
      'id': widget.old?['id'] ?? uuid.v4(),
      'date': date,
      'shopId': shopId,
      'items': clean,
      'note': note.text.trim(),
    }..removeWhere((k, v) => k == 'note' && v == '');
    if (await c.savePurchaseList(list)) {
      changed = false;
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() => error = c.message);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !changed,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Выйти без сохранения?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Остаться'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Выйти'),
            ),
          ],
        ),
      );
      if (leave == true && context.mounted) {
        changed = false;
        Navigator.pop(context);
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.old == null ? 'Новый список' : 'Список покупок'),
        actions: [
          TextButton(
            onPressed: c.busy ? null : save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(dateTitle(date)),
            subtitle: const Text('Дата покупок'),
            trailing: OutlinedButton(
              onPressed: () async {
                final d = await pickDate(context, parseDateKey(date));
                if (d != null) {
                  setState(() {
                    date = dateKey(d);
                    changed = true;
                  });
                }
              },
              child: const Text('Изменить'),
            ),
          ),
          ShopSelector(
            controller: c,
            value: shopId,
            onChanged: (v) => setState(() {
              shopId = v;
              changed = true;
            }),
          ),
          const SizedBox(height: 16),
          PurchaseItemsEditor(
            key: editor,
            controller: c,
            items: items,
            onChanged: () => changed = true,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: note,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Заметка'),
            onChanged: (_) => changed = true,
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

/// A purchase list received by e-mail: choose date, shop and items.
class ShoppingMailDialog extends StatefulWidget {
  final AppController controller;
  final Json inbox;
  const ShoppingMailDialog({
    super.key,
    required this.controller,
    required this.inbox,
  });
  @override
  State<ShoppingMailDialog> createState() => _ShoppingMailDialogState();
}

class _ShoppingMailDialogState extends State<ShoppingMailDialog> {
  AppController get c => widget.controller;
  String date = dateKey(DateTime.now());
  late String? hint = (widget.inbox['source'] as Map?)?['shopHint'];
  late String? shopId = hint == null
      ? null
      : shopsList(c.data)
            .where(
              (s) =>
                  normalizeText(s['name']).toLowerCase() ==
                  normalizeText(hint!).toLowerCase(),
            )
            .firstOrNull?['id'];
  late final List<Json> items = [
    for (final i in widget.inbox['items'] as List) Map<String, dynamic>.from(i),
  ];
  late final Set<String> chosen = {for (final i in items) i['id'] as String};
  String? error;

  @override
  Widget build(BuildContext context) {
    final source = (widget.inbox['source'] as Map?) ?? const {};
    return AlertDialog(
      title: const Text('Список покупок из почты'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'От: ${source['from'] ?? ''}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(dateTitle(date)),
                trailing: OutlinedButton(
                  onPressed: () async {
                    final d = await pickDate(context, parseDateKey(date));
                    if (d != null) setState(() => date = dateKey(d));
                  },
                  child: const Text('Дата'),
                ),
              ),
              ShopSelector(
                controller: c,
                value: shopId,
                hint: hint,
                onChanged: (v) => setState(() => shopId = v),
              ),
              if (hint != null && shopId == null)
                Text(
                  'В теме письма указан магазин «$hint» — добавьте его кнопкой справа.',
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 8),
              if (items.isEmpty)
                const Text(
                  'В письме не найдено ни одной покупки. Пишите по одной покупке в строке.',
                ),
              if (items.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Покупки: ${chosen.length} из ${items.length}',
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        chosen.length == items.length
                            ? chosen.clear()
                            : chosen.addAll(
                                items.map((i) => i['id'] as String),
                              );
                      }),
                      child: Text(
                        chosen.length == items.length
                            ? 'Снять все'
                            : 'Выбрать все',
                      ),
                    ),
                  ],
                ),
              for (final i in items)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(itemLabel(i)),
                  value: chosen.contains(i['id']),
                  onChanged: (v) => setState(
                    () => v! ? chosen.add(i['id']) : chosen.remove(i['id']),
                  ),
                ),
              if (shopId != null && listFor(c.data, date, shopId!) != null)
                const Text(
                  'На эту дату в этом магазине уже есть список — покупки добавятся в него '
                  '(повторы не дублируются).',
                  style: TextStyle(fontSize: 12),
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
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Отклонить список из письма?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Нет'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Отклонить'),
                  ),
                ],
              ),
            );
            if (ok != true) return;
            await c.save('purchase_list', widget.inbox, deleted: true);
            if (context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Отклонить'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Позже'),
        ),
        FilledButton(
          onPressed: () async {
            if (shopId == null) {
              setState(() => error = 'Выберите магазин');
              return;
            }
            final picked = items
                .where((i) => chosen.contains(i['id']))
                .toList();
            if (picked.isEmpty) {
              setState(() => error = 'Отметьте хотя бы одну покупку');
              return;
            }
            final ok = await c.acceptShoppingMail(
              widget.inbox,
              date: date,
              shopId: shopId!,
              items: picked,
            );
            if (!context.mounted) return;
            if (ok) {
              Navigator.pop(context, true);
            } else {
              setState(() => error = c.message);
            }
          },
          child: const Text('Добавить в список'),
        ),
      ],
    );
  }
}

/// Saved shops and purchase names: rename, delete.
class ShoppingCatalogPage extends StatelessWidget {
  final AppController controller;
  const ShoppingCatalogPage({super.key, required this.controller});

  Future<void> rename(BuildContext context, String kind, Json r) async {
    final name = TextEditingController(text: r['name']);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переименовать'),
        content: TextField(controller: name, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (v == null || normalizeText(v).isEmpty) return;
    await controller.save(kind, {...r, 'name': normalizeText(v)});
  }

  Widget list(BuildContext context, String kind) {
    final items = kind == 'shop'
        ? shopsList(controller.data)
        : (controller.data.visible('product').toList()..sort(
            (a, b) => (a['name'] as String).toLowerCase().compareTo(
              (b['name'] as String).toLowerCase(),
            ),
          ));
    final used = <String, int>{};
    for (final l in purchaseLists(controller.data)) {
      if (kind == 'shop') {
        used[l['shopId']] = (used[l['shopId']] ?? 0) + 1;
      } else {
        for (final i in l['items'] as List) {
          final k = normalizeText(i['text']).toLowerCase();
          used[k] = (used[k] ?? 0) + 1;
        }
      }
    }
    if (items.isEmpty) {
      return Center(
        child: Text(
          kind == 'shop'
              ? 'Магазины появятся, когда вы их добавите в списке.'
              : 'Покупки запоминаются автоматически при сохранении списка.',
        ),
      );
    }
    return ListView(
      children: [
        for (final r in items)
          ListTile(
            title: Text(r['name']),
            subtitle: Text(
              'в списках: ${kind == 'shop' ? used[r['id']] ?? 0 : used[normalizeText(r['name']).toLowerCase()] ?? 0}',
            ),
            onTap: () => rename(context, kind, r),
            trailing: IconButton(
              tooltip: 'Удалить из справочника',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (kind == 'shop' && (used[r['id']] ?? 0) > 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Магазин используется в списках — сначала удалите их',
                      ),
                    ),
                  );
                  return;
                }
                await controller.save(kind, r, deleted: true);
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Справочники покупок'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Покупки'),
              Tab(text: 'Магазины'),
            ],
          ),
        ),
        body: TabBarView(
          children: [list(context, 'product'), list(context, 'shop')],
        ),
      ),
    ),
  );
}

/// The "Покупки" tab: dates → shops → items.
class ShoppingView extends StatefulWidget {
  final AppController controller;
  final DateTime? now;
  const ShoppingView({super.key, required this.controller, this.now});
  @override
  State<ShoppingView> createState() => ShoppingViewState();
}

class ShoppingViewState extends State<ShoppingView> {
  AppController get c => widget.controller;
  bool showPast = false;
  final collapsed = <String>{};

  Future<void> open({Json? list, String? date}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PurchaseListPage(controller: c, old: list, date: date),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> toggle(Json list, Json item, bool done) async {
    await c.save('purchase_list', {
      ...list,
      'items': [
        for (final i in list['items'] as List)
          i['id'] == item['id'] ? {...i, 'done': done} : i,
      ],
    });
  }

  Future<void> deleteDate(String date, List<Json> lists) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить все списки за ${dateTitle(date)}?'),
        content: Text(
          'Магазинов: ${lists.length}. Названия покупок и магазинов останутся в справочниках.',
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
    if (ok != true) return;
    await c.run(() async {
      await c.mutate((d) {
        for (final l in lists) {
          d.write('purchase_list', l, c.device, deleted: true);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now ?? DateTime.now();
    final today = dateKey(now);
    final shops = shopsById(c.data);
    final byDate = <String, List<Json>>{};
    for (final l in purchaseLists(c.data)) {
      byDate.putIfAbsent(l['date'], () => []).add(l);
    }
    for (final v in byDate.values) {
      v.sort(
        (a, b) => ((shops[a['shopId']]?['name'] ?? '') as String)
            .toLowerCase()
            .compareTo(
              ((shops[b['shopId']]?['name'] ?? '') as String).toLowerCase(),
            ),
      );
    }
    final upcoming = byDate.keys.where((d) => d.compareTo(today) >= 0).toList()
      ..sort();
    final past = byDate.keys.where((d) => d.compareTo(today) < 0).toList()
      ..sort((a, b) => b.compareTo(a));
    final inbox = shoppingInbox(c.data);

    Widget dateSection(String date) {
      final lists = byDate[date]!;
      final total = lists.fold<int>(
        0,
        (s, l) => s + (l['items'] as List).length,
      );
      final done = lists.fold<int>(
        0,
        (s, l) =>
            s + (l['items'] as List).where((i) => i['done'] == true).length,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: ValueKey('date-$date'),
            contentPadding: const EdgeInsets.only(left: 16, right: 4),
            title: Text(
              dateTitle(date, now: now),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              'Магазинов: ${lists.length} • куплено $done из $total',
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'Действия с датой',
              onSelected: (v) =>
                  v == 'add' ? open(date: date) : deleteDate(date, lists),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'add', child: Text('Добавить магазин')),
                PopupMenuItem(value: 'delete', child: Text('Удалить дату')),
              ],
            ),
          ),
          for (final l in lists)
            () {
              final items = (l['items'] as List).cast<Json>();
              final got = items.where((i) => i['done'] == true).length;
              final key = l['id'] as String;
              final conflict = c.data.conflicted('purchase_list', key);
              final isCollapsed =
                  collapsed.contains(key) ||
                  (got == items.length && !collapsed.contains('open-$key'));
              return Card(
                margin: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.storefront_outlined),
                      title: Text(
                        shops[l['shopId']]?['name'] ?? 'Магазин удалён',
                      ),
                      subtitle: Text(
                        conflict
                            ? 'Конфликт версий — разрешите в настройках'
                            : 'Куплено $got из ${items.length}',
                      ),
                      onTap: () => setState(() {
                        if (isCollapsed) {
                          collapsed.remove(key);
                          collapsed.add('open-$key');
                        } else {
                          collapsed.add(key);
                          collapsed.remove('open-$key');
                        }
                      }),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Изменить список',
                            onPressed: conflict || c.busy
                                ? null
                                : () => open(list: l),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          Icon(
                            isCollapsed ? Icons.expand_more : Icons.expand_less,
                          ),
                        ],
                      ),
                    ),
                    if (!isCollapsed)
                      for (final i
                          in [...items]..sort(
                            (a, b) =>
                                (a['done'] == true ? 1 : 0) -
                                (b['done'] == true ? 1 : 0),
                          ))
                        CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            itemLabel(i),
                            style: i['done'] == true
                                ? const TextStyle(
                                    decoration: TextDecoration.lineThrough,
                                  )
                                : null,
                          ),
                          value: i['done'] == true,
                          onChanged: conflict || c.busy
                              ? null
                              : (v) => toggle(l, i, v!),
                        ),
                    if (l['note'] != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(l['note']),
                        ),
                      ),
                  ],
                ),
              );
            }(),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final m in inbox)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.mark_email_unread_outlined),
              title: Text(
                'Из почты: список покупок (${(m['items'] as List).length})',
              ),
              subtitle: const Text('Выберите дату и магазин'),
              trailing: FilledButton(
                onPressed: c.busy
                    ? null
                    : () => showDialog<bool>(
                        context: context,
                        builder: (_) =>
                            ShoppingMailDialog(controller: c, inbox: m),
                      ),
                child: const Text('Разобрать'),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Почта: тема «СПИСОК ПОКУПОК», по покупке в строке',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ShoppingCatalogPage(controller: c),
                  ),
                ),
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('Справочники'),
              ),
            ],
          ),
        ),
        if (byDate.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Списков покупок пока нет. Нажмите «Список», выберите дату и магазин. '
              'Введённые названия покупок и магазины запоминаются — потом их можно выбрать.',
              textAlign: TextAlign.center,
            ),
          ),
        for (final d in upcoming) dateSection(d),
        if (past.isNotEmpty)
          ListTile(
            title: Text('Прошедшие даты: ${past.length}'),
            trailing: Icon(showPast ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => showPast = !showPast),
          ),
        if (showPast || upcoming.isEmpty)
          for (final d in past) dateSection(d),
      ],
    );
  }
}
