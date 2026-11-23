// Formatting of selected text in notes and in the knowledge base:
// font, size, colour, bold, italic, underline and hyperlinks.
//
// The plain text stays in its old field ('notes' / 'text'), so search,
// Excel and older app versions keep working. Formatting is stored next to
// it as {'v': 1, 'md5': <md5 of the text>, 'runs': [{'s','e', ...}]}.
// If the text was changed by a version that does not know about
// formatting, the checksum no longer matches and the formatting is ignored.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'domain.dart' show Json;

/// Font families: key → (label, families in order of preference).
/// Windows and Android have different fonts, so each entry lists both.
const richFonts = <String, (String, List<String>)>{
  'sans': ('Без засечек', ['Arial', 'Segoe UI', 'Roboto', 'sans-serif']),
  'serif': (
    'С засечками',
    ['Times New Roman', 'Georgia', 'Noto Serif', 'serif'],
  ),
  'mono': (
    'Моноширинный',
    ['Consolas', 'Courier New', 'Roboto Mono', 'monospace'],
  ),
  'hand': ('Рукописный', ['Segoe Print', 'Comic Sans MS', 'casual', 'cursive']),
};

/// Text sizes: label → font size (null = as the field).
const richSizes = <String, double?>{
  'Мелкий': 12,
  'Обычный': null,
  'Крупный': 18,
  'Заголовок': 24,
};

const richColors = <int>[
  0xFFE53935, // красный
  0xFFFB8C00, // оранжевый
  0xFFC0A000, // жёлтый (тёмный, читается на светлом фоне)
  0xFF43A047, // зелёный
  0xFF00897B, // бирюзовый
  0xFF1E88E5, // синий
  0xFF8E24AA, // фиолетовый
  0xFF6D4C41, // коричневый
  0xFF757575, // серый
];

@immutable
class CharStyle {
  final bool bold, italic, underline;
  final int? color;
  final String? font;
  final double? size;
  final String? link;
  const CharStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.color,
    this.font,
    this.size,
    this.link,
  });

  static const plain = CharStyle();
  bool get isPlain => this == plain;

  CharStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    int? Function()? color,
    String? Function()? font,
    double? Function()? size,
    String? Function()? link,
  }) => CharStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    color: color == null ? this.color : color(),
    font: font == null ? this.font : font(),
    size: size == null ? this.size : size(),
    link: link == null ? this.link : link(),
  );

  Json toJson() => {
    if (bold) 'b': 1,
    if (italic) 'i': 1,
    if (underline) 'u': 1,
    if (color != null) 'c': color,
    if (font != null) 'f': font,
    if (size != null) 'z': size,
    if (link != null) 'l': link,
  };

  factory CharStyle.fromJson(Map j) => CharStyle(
    bold: j['b'] == 1 || j['b'] == true,
    italic: j['i'] == 1 || j['i'] == true,
    underline: j['u'] == 1 || j['u'] == true,
    color: j['c'] is int ? j['c'] : null,
    font: richFonts.containsKey(j['f']) ? j['f'] : null,
    size: j['z'] is num ? (j['z'] as num).toDouble() : null,
    link: j['l'] is String && (j['l'] as String).isNotEmpty ? j['l'] : null,
  );

  TextStyle textStyle(Color linkColor) {
    final families = font == null ? null : richFonts[font]!.$2;
    return TextStyle(
      fontWeight: bold ? FontWeight.bold : null,
      fontStyle: italic ? FontStyle.italic : null,
      decoration: underline || link != null ? TextDecoration.underline : null,
      color: link != null
          ? linkColor
          : color == null
          ? null
          : Color(color!),
      fontFamily: families?.first,
      fontFamilyFallback: families?.sublist(1),
      fontSize: size,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CharStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.color == color &&
      other.font == font &&
      other.size == size &&
      other.link == link;

  @override
  int get hashCode =>
      Object.hash(bold, italic, underline, color, font, size, link);
}

String textChecksum(String text) => md5.convert(utf8.encode(text)).toString();

/// Validates the stored formatting object (null is allowed).
bool isValidFormat(Object? f) {
  if (f == null) return true;
  if (f is! Map || f['runs'] is! List || f['md5'] is! String) return false;
  for (final r in f['runs'] as List) {
    if (r is! Map || r['s'] is! int || r['e'] is! int) return false;
    if (r['s'] < 0 || r['e'] < r['s']) return false;
  }
  return true;
}

/// Per-character styles for [text] from the stored formatting.
List<CharStyle> decodeFormat(Object? f, String text) {
  final styles = List<CharStyle>.filled(text.length, CharStyle.plain);
  if (!isValidFormat(f) || f == null) return styles;
  final m = f as Map;
  if (m['md5'] != textChecksum(text)) return styles;
  for (final r in m['runs'] as List) {
    final s = (r['s'] as int).clamp(0, text.length);
    final e = (r['e'] as int).clamp(0, text.length);
    final st = CharStyle.fromJson(r as Map);
    for (var i = s; i < e; i++) {
      styles[i] = st;
    }
  }
  return styles;
}

/// Stored formatting for [text] (null if nothing is formatted).
Json? encodeFormat(String text, List<CharStyle> styles) {
  final runs = <Json>[];
  var i = 0;
  while (i < styles.length) {
    var j = i + 1;
    while (j < styles.length && styles[j] == styles[i]) {
      j++;
    }
    if (!styles[i].isPlain) runs.add({'s': i, 'e': j, ...styles[i].toJson()});
    i = j;
  }
  if (runs.isEmpty) return null;
  return {'v': 1, 'md5': textChecksum(text), 'runs': runs};
}

/// Adds https:// to "site.ru/page"; keeps mailto:, tel:, http(s):, file:.
String normalizeLink(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return v;
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(v)) return v;
  if (v.contains('@') && !v.contains('/')) return 'mailto:$v';
  return 'https://$v';
}

Future<bool> openLink(String url) async {
  final uri = Uri.tryParse(normalizeLink(url));
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// A text controller that keeps a style for every character.
class RichTextController extends TextEditingController {
  List<CharStyle> _styles;

  /// Style for the next typed characters (set by a button with no selection).
  CharStyle? pending;

  RichTextController({String text = '', Object? format})
    : _styles = decodeFormat(format, text),
      super(text: text);

  List<CharStyle> get styles => List.unmodifiable(_styles);

  /// Formatting to save for the whole text.
  Json? get format => encodeFormat(text, _styles);

  /// Formatting for text.substring(from, to) — used when the text is trimmed.
  Json? formatOf(int from, int to) =>
      encodeFormat(text.substring(from, to), _styles.sublist(from, to));

  /// Formatting to save for text.trim().
  Json? get trimmedFormat {
    final t = text.trim();
    if (t.isEmpty) return null;
    final from = text.indexOf(t);
    return formatOf(from, from + t.length);
  }

  @override
  set value(TextEditingValue v) {
    final old = super.value;
    if (v.text != old.text) {
      _splice(old.text, v.text, v.selection);
    } else if (v.selection != old.selection) {
      pending = null;
    }
    super.value = v;
  }

  void _splice(String a, String b, TextSelection sel) {
    if (_styles.length != a.length) {
      _styles = List.filled(a.length, CharStyle.plain);
    }
    var p = 0;
    final m = a.length < b.length ? a.length : b.length;
    while (p < m && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    // Typing a repeated letter: the cursor shows where it was inserted.
    if (b.length > a.length && sel.isValid && sel.isCollapsed) {
      final at = sel.baseOffset - (b.length - a.length);
      if (at >= 0 && at < p) p = at;
    }
    var s = 0;
    while (s < m - p &&
        a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    final removedEnd = a.length - s, insertedEnd = b.length - s;
    final CharStyle base;
    if (pending != null) {
      base = pending!;
    } else if (removedEnd > p) {
      base = _styles[p]; // replacing a selection keeps its style
    } else if (p > 0) {
      base = _styles[p - 1].copyWith(link: () => null);
    } else {
      base = CharStyle.plain;
    }
    _styles = [
      ..._styles.sublist(0, p),
      ...List.filled(insertedEnd - p, base),
      ..._styles.sublist(removedEnd),
    ];
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (_styles.length != text.length || _styles.every((s) => s.isPlain)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final link = Theme.of(context).colorScheme.primary;
    final children = <TextSpan>[];
    var i = 0;
    while (i < text.length) {
      var j = i + 1;
      while (j < text.length && _styles[j] == _styles[i]) {
        j++;
      }
      children.add(
        TextSpan(
          text: text.substring(i, j),
          style: _styles[i].isPlain ? null : _styles[i].textStyle(link),
        ),
      );
      i = j;
    }
    return TextSpan(style: style, children: children);
  }

  (int, int) _range(TextSelection sel) {
    if (!sel.isValid) return (text.length, text.length);
    final a = sel.start.clamp(0, text.length),
        b = sel.end.clamp(0, text.length);
    return (a, b);
  }

  /// Style shown as "active" on the toolbar.
  CharStyle styleAt(TextSelection sel) {
    final (a, b) = _range(sel);
    if (a == b) {
      if (pending != null) return pending!;
      return a > 0 && a <= _styles.length ? _styles[a - 1] : CharStyle.plain;
    }
    return _styles[a];
  }

  /// True if every selected character satisfies [test].
  bool all(TextSelection sel, bool Function(CharStyle) test) {
    final (a, b) = _range(sel);
    if (a == b) return test(styleAt(sel));
    for (var i = a; i < b; i++) {
      if (!test(_styles[i])) return false;
    }
    return true;
  }

  /// Applies [f] to the selection, or to the next typed text if it is empty.
  void apply(TextSelection sel, CharStyle Function(CharStyle) f) {
    final (a, b) = _range(sel);
    if (a == b) {
      pending = f(styleAt(sel));
    } else {
      for (var i = a; i < b; i++) {
        _styles[i] = f(_styles[i]);
      }
    }
    notifyListeners();
  }

  void toggleBold(TextSelection sel) {
    final on = !all(sel, (s) => s.bold);
    apply(sel, (s) => s.copyWith(bold: on));
  }

  void toggleItalic(TextSelection sel) {
    final on = !all(sel, (s) => s.italic);
    apply(sel, (s) => s.copyWith(italic: on));
  }

  void toggleUnderline(TextSelection sel) {
    final on = !all(sel, (s) => s.underline);
    apply(sel, (s) => s.copyWith(underline: on));
  }

  void setColor(TextSelection sel, int? c) =>
      apply(sel, (s) => s.copyWith(color: () => c));

  void setFont(TextSelection sel, String? f) =>
      apply(sel, (s) => s.copyWith(font: () => f));

  void setSize(TextSelection sel, double? z) =>
      apply(sel, (s) => s.copyWith(size: () => z));

  void clearFormat(TextSelection sel) => apply(sel, (_) => CharStyle.plain);

  /// The whole link around [offset] (the character before or after it).
  (int, int, String)? linkAt(int offset) {
    if (_styles.length != text.length) return null;
    int? i;
    if (offset < text.length && offset >= 0 && _styles[offset].link != null) {
      i = offset;
    } else if (offset > 0 &&
        offset <= text.length &&
        _styles[offset - 1].link != null) {
      i = offset - 1;
    }
    if (i == null) return null;
    final url = _styles[i].link!;
    var a = i, b = i + 1;
    while (a > 0 && _styles[a - 1].link == url) {
      a--;
    }
    while (b < text.length && _styles[b].link == url) {
      b++;
    }
    return (a, b, url);
  }

  /// Makes text [a, b) a link (null removes it).
  void setLink(int a, int b, String? url) {
    for (var i = a; i < b; i++) {
      _styles[i] = _styles[i].copyWith(link: () => url);
    }
    notifyListeners();
  }

  /// Replaces text [a, b) with [label] linked to [url].
  void insertLink(int a, int b, String label, String url) {
    final before = text.substring(0, a), after = text.substring(b);
    final st =
        (a < _styles.length && b > a
                ? _styles[a]
                : (a > 0 ? _styles[a - 1] : CharStyle.plain))
            .copyWith(link: () => url);
    pending = null;
    final newText = before + label + after;
    _styles = [
      ..._styles.sublist(0, a),
      ...List.filled(label.length, st),
      ..._styles.sublist(b),
    ];
    super.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: a + label.length),
    );
  }
}

/// Toolbar with formatting buttons for [controller].
///
/// Buttons do not take focus and belong to the field's tap region, so the
/// selection in the text field is kept when a button is pressed.
class RichToolbar extends StatelessWidget {
  final RichTextController controller;
  const RichToolbar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final sel = controller.selection;
            final st = controller.styleAt(sel);
            final link = sel.isValid ? controller.linkAt(sel.start) : null;
            Widget toggle(
              String tip,
              IconData icon,
              bool on,
              void Function(TextSelection) f,
            ) => IconButton(
              tooltip: tip,
              isSelected: on,
              visualDensity: VisualDensity.compact,
              icon: Icon(icon),
              onPressed: () => f(controller.selection),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    toggle(
                      'Полужирный',
                      Icons.format_bold,
                      controller.all(sel, (s) => s.bold),
                      controller.toggleBold,
                    ),
                    toggle(
                      'Курсив',
                      Icons.format_italic,
                      controller.all(sel, (s) => s.italic),
                      controller.toggleItalic,
                    ),
                    toggle(
                      'Подчёркнутый',
                      Icons.format_underlined,
                      controller.all(sel, (s) => s.underline),
                      controller.toggleUnderline,
                    ),
                    _ColorButton(controller: controller, current: st.color),
                    _MenuButton<String?>(
                      key: const ValueKey('rich-font'),
                      tooltip: 'Шрифт',
                      icon: Icons.font_download_outlined,
                      items: {
                        'Как в поле': null,
                        for (final e in richFonts.entries) e.value.$1: e.key,
                      },
                      current: st.font,
                      styleOf: (v) => v == null
                          ? null
                          : CharStyle(font: v).textStyle(Colors.blue),
                      onSelected: controller.setFont,
                      controller: controller,
                    ),
                    _MenuButton<double?>(
                      key: const ValueKey('rich-size'),
                      tooltip: 'Размер',
                      icon: Icons.format_size,
                      items: richSizes,
                      current: st.size,
                      styleOf: (v) => TextStyle(fontSize: v),
                      onSelected: controller.setSize,
                      controller: controller,
                    ),
                    IconButton(
                      tooltip: 'Гиперссылка',
                      isSelected: link != null,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.link),
                      onPressed: () => editLink(context, controller),
                    ),
                    IconButton(
                      tooltip: 'Убрать форматирование',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.format_clear),
                      onPressed: () =>
                          controller.clearFormat(controller.selection),
                    ),
                  ],
                ),
                if (link != null)
                  TextButton.icon(
                    key: const ValueKey('rich-open-link'),
                    onPressed: () => openLink(link.$3),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(
                      'Открыть: ${link.$3}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ColorButton extends StatelessWidget {
  final RichTextController controller;
  final int? current;
  const _ColorButton({required this.controller, required this.current});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('rich-color'),
      tooltip: 'Цвет текста',
      visualDensity: VisualDensity.compact,
      icon: Icon(
        Icons.format_color_text,
        color: current == null ? null : Color(current!),
      ),
      onPressed: () async {
        final sel = controller.selection;
        final picked = await showDialog<int>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Цвет текста'),
            content: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in richColors)
                  InkWell(
                    key: ValueKey('rich-color-$c'),
                    onTap: () => Navigator.pop(ctx, c),
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: Color(c),
                      child: c == current
                          ? const Icon(Icons.check, color: Colors.white)
                          : null,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, -1),
                child: const Text('Как в поле'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
            ],
          ),
        );
        if (picked == null) return;
        controller.setColor(sel, picked == -1 ? null : picked);
      },
    );
  }
}

class _MenuButton<T> extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Map<String, T> items;
  final T current;
  final TextStyle? Function(T) styleOf;
  final void Function(TextSelection, T) onSelected;
  final RichTextController controller;
  const _MenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.items,
    required this.current,
    required this.styleOf,
    required this.onSelected,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    late TextSelection sel;
    return PopupMenuButton<String>(
      tooltip: tooltip,
      icon: Icon(icon),
      onOpened: () {},
      itemBuilder: (_) {
        sel = controller.selection;
        return [
          for (final e in items.entries)
            CheckedPopupMenuItem<String>(
              value: e.key,
              checked: e.value == current,
              child: Text(e.key, style: styleOf(e.value)),
            ),
        ];
      },
      onSelected: (k) => onSelected(sel, items[k] as T),
    );
  }
}

/// Dialog to add, change, open or remove a hyperlink at the selection.
Future<void> editLink(BuildContext context, RichTextController c) async {
  final sel = c.selection.isValid
      ? c.selection
      : TextSelection.collapsed(offset: c.text.length);
  final existing = c.linkAt(sel.start);
  var a = sel.start, b = sel.end;
  if (existing != null && sel.isCollapsed) {
    a = existing.$1;
    b = existing.$2;
  }
  final label = TextEditingController(text: c.text.substring(a, b));
  final url = TextEditingController(text: existing?.$3 ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(existing == null ? 'Гиперссылка' : 'Изменить ссылку'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('link-label'),
            controller: label,
            decoration: const InputDecoration(labelText: 'Текст ссылки'),
          ),
          TextField(
            key: const ValueKey('link-url'),
            controller: url,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Адрес',
              hintText: 'https://… , почта или путь к файлу',
            ),
          ),
        ],
      ),
      actions: [
        if (existing != null) ...[
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'open'),
            child: const Text('Открыть'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'remove'),
            child: const Text('Убрать ссылку'),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'ok'),
          child: const Text('Готово'),
        ),
      ],
    ),
  );
  final address = normalizeLink(url.text);
  final text = label.text.isEmpty ? address : label.text;
  label.dispose();
  url.dispose();
  switch (result) {
    case 'open':
      await openLink(existing!.$3);
    case 'remove':
      c.setLink(a, b, null);
    case 'ok' when address.isNotEmpty:
      if (text == c.text.substring(a, b) && b > a) {
        c.setLink(a, b, address);
      } else {
        c.insertLink(a, b, text, address);
      }
  }
}

/// Read-only formatted text with clickable links (for previews).
class RichTextView extends StatelessWidget {
  final String text;
  final Object? format;
  final int? maxLines;
  final TextStyle? style;
  const RichTextView(
    this.text, {
    super.key,
    this.format,
    this.maxLines,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final styles = decodeFormat(format, text);
    final linkColor = Theme.of(context).colorScheme.primary;
    final spans = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      var j = i + 1;
      while (j < text.length && styles[j] == styles[i]) {
        j++;
      }
      final st = styles[i];
      spans.add(
        TextSpan(
          text: text.substring(i, j),
          style: st.isPlain ? null : st.textStyle(linkColor),
          recognizer: st.link == null
              ? null
              : (TapGestureRecognizer()..onTap = () => openLink(st.link!)),
        ),
      );
      i = j;
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}
