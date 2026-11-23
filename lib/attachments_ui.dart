import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import 'attachments.dart';
import 'controller.dart';
import 'domain.dart';
import 'sketch.dart';

typedef PickedFile = ({String path, String? name, String? kind});

class AttachmentsSection extends StatelessWidget {
  final AppController controller;
  final List<Json> attachments;
  final bool busy;
  final Future<void> Function(Future<List<PickedFile>> Function()) onAdd;
  final void Function(Json) onRemove;
  const AttachmentsSection({
    super.key,
    required this.controller,
    required this.attachments,
    required this.busy,
    required this.onAdd,
    required this.onRemove,
  });

  static const icons = {
    'audio': Icons.mic_none,
    'image': Icons.image_outlined,
    'video': Icons.movie_outlined,
    'file': Icons.insert_drive_file_outlined,
  };

  String stamp() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  Future<List<PickedFile>> pickFiles() async {
    final files = await openFiles();
    return [for (final f in files) (path: f.path, name: f.name, kind: null)];
  }

  Future<List<PickedFile>> camera({required bool video}) async {
    final picker = ImagePicker();
    final f = video
        ? await picker.pickVideo(source: ImageSource.camera)
        : await picker.pickImage(source: ImageSource.camera, imageQuality: 90);
    if (f == null) return [];
    final ext = p.extension(f.path).isEmpty
        ? (video ? '.mp4' : '.jpg')
        : p.extension(f.path);
    return [
      (
        path: f.path,
        name: '${video ? 'Видео' : 'Фото'}_${stamp()}$ext',
        kind: video ? 'video' : 'image',
      ),
    ];
  }

  Future<List<PickedFile>> gallery() async {
    final files = await ImagePicker().pickMultipleMedia();
    return [for (final f in files) (path: f.path, name: f.name, kind: null)];
  }

  Future<void> open(BuildContext context, Json a) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final file = await controller.fetchAttachment(a);
      if (Platform.isAndroid) {
        final r = await OpenFilex.open(file.path);
        if (r.type != ResultType.done) throw StateError(r.message);
      } else if (!await launchUrl(Uri.file(file.path))) {
        throw StateError('Нет программы для открытия файла');
      }
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('${a['name']}: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Вложения (${attachments.length})'),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      final path = await showDialog<String>(
                        context: context,
                        builder: (_) => const VoiceRecorder(),
                      );
                      if (path != null) {
                        await onAdd(
                          () async => [
                            (
                              path: path,
                              name: 'Голос_${stamp()}.m4a',
                              kind: 'audio',
                            ),
                          ],
                        );
                        await File(path).delete().catchError((_) => File(path));
                      }
                    },
              icon: const Icon(Icons.mic),
              label: const Text('Голос'),
            ),
            if (Platform.isAndroid) ...[
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => onAdd(() => camera(video: false)),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Фото'),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => onAdd(() => camera(video: true)),
                icon: const Icon(Icons.videocam_outlined),
                label: const Text('Видео'),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => onAdd(gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Галерея'),
              ),
            ],
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      final path = await Navigator.of(context).push<String>(
                        MaterialPageRoute(
                          fullscreenDialog: true,
                          builder: (_) => const SketchPage(),
                        ),
                      );
                      if (path == null) return;
                      await onAdd(
                        () async => [
                          (
                            path: path,
                            name: 'Рисунок_${stamp()}.png',
                            kind: 'image',
                          ),
                        ],
                      );
                      await File(path).delete().catchError((_) => File(path));
                    },
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Рисунок'),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => onAdd(pickFiles),
              icon: const Icon(Icons.attach_file),
              label: Text(Platform.isAndroid ? 'Файлы' : 'Файлы, фото, видео'),
            ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        for (final a in attachments)
          FutureBuilder<bool>(
            key: ValueKey('${a['id']}:${controller.downloading.length}'),
            future: controller.files.available(a),
            builder: (context, snap) {
              final local = snap.data == true;
              final loading = controller.downloading.contains(a['sha256']);
              final unsent =
                  local &&
                  controller.provider != 'none' &&
                  !controller.uploadedBlobs.contains(a['sha256']);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: a['kind'] == 'image' && local
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.file(
                          controller.files.file(a),
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          cacheWidth: 96,
                          errorBuilder: (_, _, _) => Icon(icons[a['kind']]),
                        ),
                      )
                    : Icon(icons[a['kind']] ?? Icons.insert_drive_file),
                title: Text(a['name'], overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${sizeLabel(a['size'])}'
                  '${unsent
                      ? ' • ещё не отправлен в облако'
                      : local
                      ? ''
                      : loading
                      ? ' • скачивание…'
                      : ' • в облаке, нажмите для загрузки'}',
                ),
                onTap: loading ? null : () => open(context, a),
                trailing: IconButton(
                  tooltip: 'Убрать из задачи',
                  icon: const Icon(Icons.close),
                  onPressed: busy ? null : () => onRemove(a),
                ),
              );
            },
          ),
      ],
    ),
  );
}

class VoiceRecorder extends StatefulWidget {
  const VoiceRecorder({super.key});
  @override
  State<VoiceRecorder> createState() => _VoiceRecorderState();
}

class _VoiceRecorderState extends State<VoiceRecorder> {
  final recorder = AudioRecorder();
  final watch = Stopwatch();
  String? path;
  String? error;
  bool recording = false;
  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> start() async {
    try {
      if (!await recorder.hasPermission()) {
        setState(
          () => error = 'Нет доступа к микрофону. Разрешите его в настройках.',
        );
        return;
      }
      final dir = await getTemporaryDirectory();
      path = p.join(dir.path, 'voice_${uuid.v4()}.m4a');
      await recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
        path: path!,
      );
      watch.start();
      setState(() => recording = true);
      tick();
    } catch (e) {
      if (mounted) setState(() => error = 'Запись не началась: $e');
    }
  }

  Future<void> tick() async {
    while (mounted && recording) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) setState(() {});
    }
  }

  Future<void> stop({required bool keep}) async {
    String? result;
    try {
      result = await recorder.stop();
    } catch (_) {}
    recording = false;
    watch.stop();
    if (!keep && result != null) {
      await File(result).delete().catchError((_) => File(result!));
    }
    if (mounted) Navigator.pop(context, keep ? result : null);
  }

  @override
  void dispose() {
    recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = watch.elapsed.inSeconds;
    return AlertDialog(
      title: const Text('Голосовая запись'),
      content: Row(
        children: [
          Icon(
            recording ? Icons.fiber_manual_record : Icons.mic_off,
            color: recording ? Colors.red : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              error ??
                  (recording
                      ? 'Идёт запись  ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}'
                      : 'Подготовка…'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => stop(keep: false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: recording ? () => stop(keep: true) : null,
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
