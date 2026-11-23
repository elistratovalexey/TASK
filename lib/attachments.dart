import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'domain.dart';

/// Max size of one attachment (photo, video, voice note, other file).
const maxAttachmentBytes = 1024 * 1024 * 1024;

String attachmentKind(String name) {
  final ext = p.extension(name).toLowerCase();
  const audio = ['.m4a', '.aac', '.mp3', '.wav', '.ogg', '.opus', '.flac'];
  const image = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp'];
  const video = ['.mp4', '.mov', '.mkv', '.avi', '.webm', '.3gp', '.wmv'];
  if (audio.contains(ext)) return 'audio';
  if (image.contains(ext)) return 'image';
  if (video.contains(ext)) return 'video';
  return 'file';
}

String sizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
}

Future<String> sha256OfFile(File file) async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return out.value.toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Content-addressed local storage: identical files are stored once.
class AttachmentStore {
  final Directory directory;
  AttachmentStore(Directory dataDirectory)
    : directory = Directory(p.join(dataDirectory.path, 'attachments'));

  static String safeExtension(String name) {
    final ext = p.extension(name).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext) ? ext : '.bin';
  }

  File file(Json a) =>
      File(p.join(directory.path, '${a['sha256']}${safeExtension(a['name'])}'));

  Future<bool> available(Json a) async {
    final f = file(a);
    return await f.exists() && await f.length() == a['size'];
  }

  /// Copies a file into the store and returns attachment metadata.
  Future<Json> import(String sourcePath, {String? name, String? kind}) async {
    final source = File(sourcePath);
    final size = await source.length();
    if (size > maxAttachmentBytes) {
      throw StateError(
        'Файл больше ${sizeLabel(maxAttachmentBytes)}: ${p.basename(sourcePath)}',
      );
    }
    await directory.create(recursive: true);
    final tmp = File(p.join(directory.path, 'import_${uuid.v4()}.tmp'));
    try {
      await source.openRead().pipe(tmp.openWrite());
      final hash = await sha256OfFile(tmp);
      var fileName = (name ?? p.basename(sourcePath)).trim();
      if (fileName.isEmpty) fileName = 'file';
      if (fileName.length > 200) {
        fileName = fileName.substring(0, 190) + safeExtension(fileName);
      }
      final meta = <String, dynamic>{
        'id': uuid.v4(),
        'name': fileName,
        'size': size,
        'sha256': hash,
        'kind': kind ?? attachmentKind(fileName),
        'addedAt': DateTime.now().toUtc().toIso8601String(),
      };
      final target = file(meta);
      if (await target.exists() && await target.length() == size) {
        await tmp.delete();
      } else {
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
      }
      return meta;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// Verifies a downloaded file and moves it into place.
  Future<void> accept(File downloaded, Json a) async {
    if (await downloaded.length() != a['size'] ||
        await sha256OfFile(downloaded) != a['sha256']) {
      await downloaded.delete();
      throw StateError('Файл из облака повреждён: ${a['name']}');
    }
    final target = file(a);
    if (await target.exists()) await target.delete();
    await downloaded.rename(target.path);
  }

  File temp() => File(p.join(directory.path, 'download_${uuid.v4()}.tmp'));

  /// All attachments referenced by any stored version (including conflicts
  /// and deleted tasks, so that restoring a version never loses a file).
  static List<Json> referenced(Dataset data) {
    final out = <String, Json>{};
    for (final versions in data.records.values) {
      for (final v in versions) {
        if (v['kind'] != 'task' && v['kind'] != 'note') continue;
        for (final a in (v['data']['attachments'] as List?) ?? const []) {
          out[a['sha256']] = Map<String, dynamic>.from(a);
        }
      }
    }
    return out.values.toList();
  }
}
