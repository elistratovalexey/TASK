import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain.dart';

class Repository {
  final Directory directory;
  RandomAccessFile? _instanceLock;
  Repository(this.directory);
  File get current => File(p.join(directory.path, 'data_v2.json'));
  File get previous => File('${current.path}.previous');
  Directory get backups => Directory(p.join(directory.path, 'backups'));

  static Future<Repository> open() async {
    final repo = Repository(await getApplicationSupportDirectory());
    await repo.directory.create(recursive: true);
    repo._instanceLock = await File(
      p.join(repo.directory.path, 'instance.lock'),
    ).open(mode: FileMode.append);
    try {
      await repo._instanceLock!.lock(FileLock.exclusive);
    } catch (_) {
      await repo._instanceLock!.close();
      throw StateError(
        'Приложение уже открыто. Закройте второе окно и повторите.',
      );
    }
    return repo;
  }

  Future<void> close() async => _instanceLock?.close();

  Future<Dataset> load(SharedPreferences prefs) async {
    await directory.create(recursive: true);
    if (await current.exists()) {
      return Dataset.decode(await current.readAsString());
    }
    if (await previous.exists()) {
      final data = Dataset.decode(await previous.readAsString());
      await previous.copy(current.path);
      return data;
    }
    final old = prefs.getString('data_v1');
    final data = old == null ? Dataset() : Dataset.migrate(old);
    if (old != null) {
      await File(
        p.join(directory.path, 'legacy_v1_original.json'),
      ).writeAsString(old, flush: true);
    }
    await save(data);
    return data;
  }

  Future<File> backup(Dataset data) async {
    await backups.create(recursive: true);
    final file = File(
      p.join(
        backups.path,
        'backup_${DateTime.now().toUtc().microsecondsSinceEpoch}_${uuid.v4()}.json',
      ),
    );
    await file.writeAsString(data.encode(), flush: true);
    final files = await backups
        .list()
        .where(
          (f) =>
              f is File &&
              p.basename(f.path).startsWith('backup_') &&
              f.path.endsWith('.json'),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    // This directory is owned by this app; exported backups are never removed.
    for (final f in files.take(files.length > 30 ? files.length - 30 : 0)) {
      await f.delete();
    }
    return file;
  }

  Future<void> save(Dataset data) async {
    final encoded = data.encode();
    Dataset.decode(encoded); // Validate before touching the last good copy.
    await directory.create(recursive: true);
    if (await current.exists()) {
      await backup(Dataset.decode(await current.readAsString()));
    }
    final tmp = File('${current.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    if (await current.exists()) {
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    }
    try {
      await tmp.rename(current.path);
    } catch (_) {
      if (!await current.exists() && await previous.exists()) {
        await previous.copy(current.path);
      }
      rethrow;
    }
  }

  // Restore is an explicit new edit, not a rollback of synchronization clocks.
  Dataset restore(Dataset currentData, Dataset backupData, String device) {
    if (backupData.conflicts.isNotEmpty) {
      throw const FormatException(
        'Сначала разрешите конфликты в резервной копии',
      );
    }
    final out = currentData.merge(backupData);
    for (final key in out.records.keys.toList()) {
      final version = backupData.records[key]?.first ?? out.records[key]!.first;
      out.write(
        version['kind'],
        clone(version['data']),
        device,
        deleted: backupData.records[key] == null || version['deleted'] == true,
      );
    }
    return out;
  }
}
