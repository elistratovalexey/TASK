import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'domain.dart';

/// One continuous line. Width is multiplied by stylus pressure per point.
class Stroke {
  final Color color;
  final double width;
  final bool eraser;
  final List<({Offset at, double pressure})> points = [];
  Stroke(this.color, this.width, {this.eraser = false});
}

class SketchPainter extends CustomPainter {
  final List<Stroke> strokes;
  final int revision;
  SketchPainter(this.strokes, this.revision);

  static void paintStrokes(Canvas canvas, Size size, List<Stroke> strokes) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.eraser ? Colors.white : s.color
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        final pt = s.points.first;
        canvas.drawCircle(
          pt.at,
          s.width * pt.pressure / 2,
          Paint()..color = paint.color,
        );
        continue;
      }
      for (var i = 1; i < s.points.length; i++) {
        final a = s.points[i - 1];
        final b = s.points[i];
        paint.strokeWidth = s.width * (a.pressure + b.pressure) / 2;
        canvas.drawLine(a.at, b.at, paint);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) => paintStrokes(canvas, size, strokes);

  @override
  bool shouldRepaint(SketchPainter old) => old.revision != revision;
}

/// Full-screen drawing page. Returns a path to a PNG file or null.
class SketchPage extends StatefulWidget {
  /// Folder for the PNG file; the system temp folder by default.
  final Future<Directory> Function() directory;
  const SketchPage({super.key, this.directory = getTemporaryDirectory});
  @override
  State<SketchPage> createState() => _SketchPageState();
}

class _SketchPageState extends State<SketchPage> {
  static const colors = [
    Colors.black,
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
  ];
  static const widths = [2.0, 4.0, 8.0, 16.0];
  final strokes = <Stroke>[];
  final redo = <Stroke>[];
  Color color = Colors.black;
  double width = 4;
  bool eraser = false;
  bool penOnly = false;
  bool saving = false;
  int revision = 0;
  Size canvasSize = Size.zero;
  int? activePointer;

  bool accepts(PointerEvent e) =>
      !penOnly ||
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus ||
      e.kind == PointerDeviceKind.mouse;

  double pressure(PointerEvent e) {
    if (e.kind != PointerDeviceKind.stylus &&
        e.kind != PointerDeviceKind.invertedStylus) {
      return 1;
    }
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 1;
    return (0.3 + 1.2 * ((e.pressure - e.pressureMin) / range)).clamp(0.3, 1.5);
  }

  void down(PointerDownEvent e) {
    if (activePointer != null || !accepts(e)) return;
    activePointer = e.pointer;
    final rubber = eraser || e.kind == PointerDeviceKind.invertedStylus;
    setState(() {
      strokes.add(
        Stroke(color, rubber ? width * 3 : width, eraser: rubber)
          ..points.add((at: e.localPosition, pressure: pressure(e))),
      );
      redo.clear();
      revision++;
    });
  }

  void move(PointerMoveEvent e) {
    if (e.pointer != activePointer) return;
    setState(() {
      strokes.last.points.add((at: e.localPosition, pressure: pressure(e)));
      revision++;
    });
  }

  void up(PointerEvent e) {
    if (e.pointer == activePointer) activePointer = null;
  }

  Future<void> save() async {
    if (strokes.isEmpty || canvasSize.isEmpty) return;
    setState(() => saving = true);
    try {
      final ratio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(ratio);
      SketchPainter.paintStrokes(canvas, canvasSize, strokes);
      final image = await recorder.endRecording().toImage(
        (canvasSize.width * ratio).round(),
        (canvasSize.height * ratio).round(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = await widget.directory();
      final file = File(p.join(dir.path, 'sketch_${uuid.v4()}.png'));
      await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      if (mounted) Navigator.pop(context, file.path);
    } catch (e) {
      if (mounted) {
        setState(() => saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Рисунок не сохранён: $e')));
      }
    }
  }

  Future<bool> discard() async {
    if (strokes.isEmpty) return true;
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Выйти без сохранения?'),
        content: const Text('Рисунок будет потерян.'),
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
    return yes == true;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: strokes.isEmpty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final navigator = Navigator.of(context);
      if (await discard()) navigator.pop();
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Рисунок'),
        actions: [
          IconButton(
            tooltip: 'Отменить',
            onPressed: strokes.isEmpty
                ? null
                : () => setState(() {
                    redo.add(strokes.removeLast());
                    revision++;
                  }),
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Повторить',
            onPressed: redo.isEmpty
                ? null
                : () => setState(() {
                    strokes.add(redo.removeLast());
                    revision++;
                  }),
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: 'Очистить',
            onPressed: strokes.isEmpty
                ? null
                : () => setState(() {
                    redo
                      ..clear()
                      ..addAll(strokes.reversed);
                    strokes.clear();
                    revision++;
                  }),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          TextButton(
            onPressed: strokes.isEmpty || saving ? null : save,
            child: const Text('Готово'),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            elevation: 1,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  for (final c in colors)
                    IconButton(
                      tooltip: 'Цвет',
                      onPressed: () => setState(() {
                        color = c;
                        eraser = false;
                      }),
                      icon: Icon(
                        !eraser && color == c
                            ? Icons.radio_button_checked
                            : Icons.circle,
                        color: c,
                      ),
                    ),
                  const VerticalDivider(),
                  for (final w in widths)
                    IconButton(
                      tooltip: 'Толщина ${w.toInt()}',
                      isSelected: width == w,
                      onPressed: () => setState(() => width = w),
                      icon: Container(
                        width: 24,
                        height: w.clamp(2, 14),
                        decoration: BoxDecoration(
                          color: width == w
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  const VerticalDivider(),
                  IconButton(
                    tooltip: 'Ластик',
                    isSelected: eraser,
                    onPressed: () => setState(() => eraser = !eraser),
                    icon: Icon(
                      Icons.auto_fix_normal,
                      color: eraser
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  FilterChip(
                    label: const Text('Только перо'),
                    tooltip: 'Касания ладонью и пальцем не рисуют',
                    selected: penOnly,
                    onSelected: (v) => setState(() => penOnly = v),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, box) {
                canvasSize = Size(box.maxWidth, box.maxHeight);
                return Listener(
                  onPointerDown: down,
                  onPointerMove: move,
                  onPointerUp: up,
                  onPointerCancel: up,
                  child: ClipRect(
                    child: CustomPaint(
                      size: canvasSize,
                      painter: SketchPainter(strokes, revision),
                    ),
                  ),
                );
              },
            ),
          ),
          if (saving) const LinearProgressIndicator(),
        ],
      ),
    ),
  );
}
