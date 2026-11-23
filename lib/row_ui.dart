import 'package:flutter/material.dart';
import 'domain.dart';

/// Row colors for tasks, knowledge base entries and checklist items.
/// Stored by key, so that the palette can be adjusted without breaking data.
const rowColors = <String, ({Color color, String name})>{
  'red': (color: Color(0xFFE53935), name: 'Красный'),
  'orange': (color: Color(0xFFFB8C00), name: 'Оранжевый'),
  'yellow': (color: Color(0xFFFDD835), name: 'Жёлтый'),
  'green': (color: Color(0xFF43A047), name: 'Зелёный'),
  'blue': (color: Color(0xFF1E88E5), name: 'Синий'),
  'purple': (color: Color(0xFF8E24AA), name: 'Фиолетовый'),
  'grey': (color: Color(0xFF757575), name: 'Серый'),
};

Color? rowColor(dynamic key) => rowColors[key]?.color;

/// Light tint of the row color. Text keeps the theme color, so it stays
/// readable in both light and dark themes.
Color? rowTint(BuildContext context, dynamic key) {
  final c = rowColor(key);
  if (c == null) return null;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Color.alphaBlend(
    c.withValues(alpha: dark ? 0.22 : 0.14),
    Theme.of(context).colorScheme.surface,
  );
}

/// Colored stripe on the left edge of a row.
class ColorStripe extends StatelessWidget {
  final dynamic colorKey;
  final Widget child;
  const ColorStripe({super.key, required this.colorKey, required this.child});
  @override
  Widget build(BuildContext context) {
    final c = rowColor(colorKey);
    if (c == null) return child;
    // Material (not a colored Container): ListTile ink and backgrounds are
    // painted on the nearest Material and stay visible.
    return Material(
      color: rowTint(context, colorKey),
      shape: Border(left: BorderSide(color: c, width: 6)),
      child: Padding(padding: const EdgeInsets.only(left: 6), child: child),
    );
  }
}

class ColorPicker extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  const ColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Цвет строки',
  });

  Widget dot(BuildContext context, String? key) {
    final selected = value == key;
    final c = rowColor(key);
    final outline = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: key == null ? 'Без цвета' : rowColors[key]!.name,
      child: InkResponse(
        onTap: () => onChanged(key),
        radius: 22,
        child: Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? outline : outline.withValues(alpha: 0.3),
              width: selected ? 3 : 1,
            ),
          ),
          child: key == null
              ? Icon(
                  Icons.format_color_reset_outlined,
                  size: 18,
                  color: outline,
                )
              : selected
              ? Icon(
                  Icons.check,
                  size: 18,
                  color: key == 'yellow' ? Colors.black : Colors.white,
                )
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      Wrap(
        children: [
          dot(context, null),
          for (final k in rowColors.keys) dot(context, k),
        ],
      ),
    ],
  );
}

Future<String?> pickColorDialog(BuildContext context, String? current) async {
  final result = await showDialog<({String? key})>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Цвет пункта'),
      content: ColorPicker(
        value: current,
        label: '',
        onChanged: (k) => Navigator.pop(ctx, (key: k)),
      ),
    ),
  );
  return result == null ? current : result.key;
}

/// Checklist being edited: items plus the text of a not yet added item.
class ChecklistController {
  final List<Json> items;
  final input = TextEditingController();
  ChecklistController(List? initial)
    : items = [for (final c in initial ?? const []) clone(c)];

  /// Adds the typed text as a new item. Returns false if nothing was typed.
  bool addPending() {
    final t = input.text.trim();
    if (t.isEmpty) return false;
    items.add({'id': uuid.v4(), 'text': t, 'done': false});
    input.clear();
    return true;
  }

  bool get hasEmptyItems =>
      items.any((c) => (c['text'] as String).trim().isEmpty);
  void dispose() => input.dispose();
}

class ChecklistEditor extends StatefulWidget {
  final ChecklistController controller;
  final VoidCallback? onChanged;
  const ChecklistEditor({super.key, required this.controller, this.onChanged});
  @override
  State<ChecklistEditor> createState() => _ChecklistEditorState();
}

class _ChecklistEditorState extends State<ChecklistEditor> {
  List<Json> get items => widget.controller.items;
  void changed(VoidCallback f) {
    setState(f);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final done = items.where((c) => c['done'] == true).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(items.isEmpty ? 'Чек-лист' : 'Чек-лист: $done из ${items.length}'),
        for (var i = 0; i < items.length; i++)
          Container(
            key: ValueKey('row-${items[i]['id']}'),
            margin: const EdgeInsets.only(top: 2),
            child: ColorStripe(
              colorKey: items[i]['color'],
              child: Row(
                children: [
                  Checkbox(
                    value: items[i]['done'],
                    onChanged: (v) => changed(() => items[i]['done'] = v),
                  ),
                  Expanded(
                    child: TextFormField(
                      key: ValueKey(items[i]['id']),
                      initialValue: items[i]['text'],
                      maxLines: null,
                      style: TextStyle(
                        decoration: items[i]['done'] == true
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                      onChanged: (v) {
                        items[i]['text'] = v.trim();
                        widget.onChanged?.call();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Цвет пункта',
                    onPressed: () async {
                      final k = await pickColorDialog(
                        context,
                        items[i]['color'],
                      );
                      if (!mounted) return;
                      changed(() {
                        if (k == null) {
                          items[i].remove('color');
                        } else {
                          items[i]['color'] = k;
                        }
                      });
                    },
                    icon: Icon(
                      Icons.palette_outlined,
                      color: rowColor(items[i]['color']),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Удалить пункт',
                    onPressed: () => changed(() => items.removeAt(i)),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller.input,
                decoration: const InputDecoration(labelText: 'Новый пункт'),
                onSubmitted: (_) => changed(widget.controller.addPending),
              ),
            ),
            IconButton(
              tooltip: 'Добавить пункт',
              onPressed: () => changed(widget.controller.addPending),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }
}
