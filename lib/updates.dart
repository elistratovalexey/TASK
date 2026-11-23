import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'version.dart';

/// update.json in the cloud folder: the newest published build.
class UpdateManifest {
  final String version;
  final String notes;
  final String publishedAt;
  final Map<String, Map<String, dynamic>> files; // 'windows' / 'android'
  UpdateManifest(this.version, this.notes, this.publishedAt, this.files);

  static UpdateManifest parse(String text) {
    final j = jsonDecode(text);
    if (j is! Map ||
        j['version'] is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(j['version']) ||
        j['files'] is! Map) {
      throw const FormatException('Повреждён файл описания обновления');
    }
    final files = <String, Map<String, dynamic>>{};
    (j['files'] as Map).forEach((k, v) {
      if (k is String &&
          v is Map &&
          v['sha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(v['sha256']) &&
          v['size'] is int &&
          v['name'] is String) {
        files[k] = Map<String, dynamic>.from(v);
      }
    });
    return UpdateManifest(
      j['version'],
      j['notes'] is String ? j['notes'] : '',
      j['publishedAt'] is String ? j['publishedAt'] : '',
      files,
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'version': version,
    'notes': notes,
    'publishedAt': publishedAt,
    'files': files,
  });

  bool get newer => compareVersions(version, appVersion) > 0;
}

String get platformKey => Platform.isWindows ? 'windows' : 'android';

/// Reads Identity Version="1.2.3.0" from an .msix package.
String? msixVersion(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifest = archive.findFile('AppxManifest.xml');
    if (manifest == null) return null;
    final xml = utf8.decode(
      manifest.content as List<int>,
      allowMalformed: true,
    );
    final m = RegExp(
      r'<Identity\b[^>]*\bVersion="(\d+)\.(\d+)\.(\d+)',
    ).firstMatch(xml);
    return m == null ? null : '${m[1]}.${m[2]}.${m[3]}';
  } catch (_) {
    return null;
  }
}
