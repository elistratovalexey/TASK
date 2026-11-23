import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_reminders/attachments.dart';
import 'package:project_reminders/cloud.dart';
import 'package:project_reminders/controller.dart';
import 'package:project_reminders/domain.dart';
import 'package:project_reminders/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'domain_test.dart' show base, task;

/// In-memory cloud with the same semantics as Mail/Google stores.
class MemoryStore implements CloudStore {
  final Map<String, String> snapshots = {};
  final Map<String, List<int>> blobs = {};
  void Function()? afterList;
  int uploads = 0;
  bool failBlobs = false;
  final log = <String>[];
  @override
  Future<List<String>> list() async {
    final ids = snapshots.keys.toList()..sort();
    afterList?.call();
    return ids;
  }

  @override
  Future<Dataset> read(String id) async => Dataset.decode(snapshots[id]!);
  @override
  Future<void> upload(Dataset data) async {
    uploads++;
    log.add('snapshot');
    snapshots['snapshot_${uuid.v4()}.json'] = data.encode();
  }

  @override
  Future<void> delete(String id) async => snapshots.remove(id);
  @override
  Future<bool> hasBlob(String sha) async => blobs.containsKey(sha);
  @override
  Future<void> putBlob(String sha, File file) async {
    if (failBlobs) throw CloudFailure('Загрузка вложения в Mail: HTTP 500');
    log.add('blob');
    blobs[sha] = await file.readAsBytes();
  }

  @override
  Future<void> getBlob(String sha, File target) async =>
      target.writeAsBytes(blobs[sha]!);
  final Map<String, String> texts = {};
  @override
  Future<String?> readText(String name) async => texts[checkedTextName(name)];
  @override
  Future<void> writeText(String name, String text) async =>
      texts[checkedTextName(name)] = text;
  @override
  void close() {}
}

class TestController extends AppController {
  final MemoryStore store;
  TestController(super.repository, super.prefs, this.store)
    : super(notifications: false);
  @override
  Future<CloudStore> openStore({bool interactive = true}) async => store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Дерево подпроектов', () {
    final projects = <Json>[
      {'id': 'a', 'name': 'Завод'},
      {'id': 'b', 'name': 'Линия 1', 'parentId': 'a'},
      {'id': 'c', 'name': 'Робот', 'parentId': 'b'},
      {'id': 'd', 'name': 'Склад'},
    ];
    test('Порядок, глубина, путь и поддерево', () {
      final t = ProjectTree(projects);
      expect(
        t.flatten().map((e) => '${e.project['id']}${e.depth}').join(),
        'a0b1c2d0',
      );
      expect(t.path('c'), 'Завод / Линия 1 / Робот');
      expect(t.subtree('a'), {'a', 'b', 'c'});
      expect(t.subtree('d'), {'d'});
    });
    test('Цикл после параллельных правок не зацикливает программу', () {
      final t = ProjectTree([
        {'id': 'x', 'name': 'X', 'parentId': 'y'},
        {'id': 'y', 'name': 'Y', 'parentId': 'x'},
      ]);
      expect(t.flatten(), hasLength(2));
      expect(t.roots, isNotEmpty);
    });
    test('Проект с несуществующим родителем показывается в корне', () {
      final t = ProjectTree([
        {'id': 'x', 'name': 'X', 'parentId': 'deleted'},
      ]);
      expect(t.roots.single['id'], 'x');
    });
    test('Проверка parentId', () {
      expect(
        () => Dataset.validateData('project', {
          'id': 'p',
          'name': 'P',
          'parentId': 'p',
        }),
        throwsFormatException,
      );
      Dataset.validateData('project', {
        'id': 'p',
        'name': 'P',
        'parentId': null,
      });
    });
  });

  group('Вложения', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('att_'));
    tearDown(() async => dir.delete(recursive: true));
    test('Импорт, дедупликация и проверка задачи', () async {
      final src = File('${dir.path}/photo.JPG')..writeAsBytesSync([1, 2, 3]);
      final store = AttachmentStore(dir);
      final a = await store.import(src.path);
      final b = await store.import(src.path);
      expect(a['kind'], 'image');
      expect(a['sha256'], b['sha256']);
      expect(await store.available(a), isTrue);
      expect(store.directory.listSync(), hasLength(1));
      Dataset.validateData('task', {
        ...task(),
        'attachments': [a],
      });
      expect(
        () => Dataset.validateData('task', {
          ...task(),
          'attachments': [
            {...a, 'sha256': 'bad'},
          ],
        }),
        throwsFormatException,
      );
    });
    test('Повреждённый файл из облака отклоняется', () async {
      final store = AttachmentStore(dir);
      final src = File('${dir.path}/a.txt')..writeAsStringSync('abc');
      final a = await store.import(src.path);
      await store.file(a).delete();
      final tmp = store.temp()..writeAsStringSync('xyz');
      await expectLater(store.accept(tmp, a), throwsStateError);
      expect(await store.available(a), isFalse);
    });
  });

  group('Автосинхронизация', () {
    late Directory dir;
    late SharedPreferences prefs;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sync_');
      SharedPreferences.setMockInitialValues({
        'provider': 'mail',
        'auto_sync': true,
        'sync_interval': 0,
      });
      prefs = await SharedPreferences.getInstance();
    });
    tearDown(() async => dir.delete(recursive: true));

    test('Старые снимки удаляются, чужие правки не теряются', () async {
      final cloud = MemoryStore();
      cloud.snapshots['snapshot_old1.json'] = base().encode();
      cloud.snapshots['snapshot_old2.json'] =
          (base()
                ..write('task', {...task(id: 'u'), 'title': 'С телефона'}, 'B'))
              .encode();
      final c = TestController(
        Repository(Directory('${dir.path}/a')),
        prefs,
        cloud,
      );
      await c.load();
      await c.sync();
      expect(c.syncError, isNull);
      expect(cloud.snapshots, hasLength(1));
      expect(
        c.data.visible('task').map((t) => t['title']),
        contains('С телефона'),
      );

      // Another device uploads while this one is syncing: must survive.
      cloud.afterList = () {
        cloud.snapshots['snapshot_zz_new.json'] =
            (base()..write('task', {
                  ...task(id: 'n'),
                  'title': 'Параллельно',
                }, 'C'))
                .encode();
        cloud.afterList = null;
      };
      await c.sync();
      expect(cloud.snapshots.keys, contains('snapshot_zz_new.json'));
      await c.sync();
      expect(
        c.data.visible('task').map((t) => t['title']),
        contains('Параллельно'),
      );
      expect(cloud.snapshots, hasLength(1));
      c.dispose();
    });

    test('Без изменений повторная выгрузка не выполняется', () async {
      final cloud = MemoryStore();
      final c = TestController(
        Repository(Directory('${dir.path}/b')),
        prefs,
        cloud,
      );
      await c.load();
      await c.sync();
      final n = cloud.uploads;
      await c.sync();
      expect(cloud.uploads, n);
      c.dispose();
    });

    test('Вложение передаётся на второе устройство', () async {
      final cloud = MemoryStore();
      final a = TestController(
        Repository(Directory('${dir.path}/pc')),
        prefs,
        cloud,
      );
      await a.load();
      final src = File('${dir.path}/voice.m4a')
        ..writeAsBytesSync(List.filled(5000, 7));
      final meta = await a.files.import(src.path);
      await a.save('project', {'id': 'p', 'name': 'Проект'});
      await a.save('task', {
        ...task(),
        'attachments': [meta],
      });
      await a.sync();
      expect(cloud.blobs.keys, [meta['sha256']]);
      a.dispose();

      SharedPreferences.setMockInitialValues({
        'provider': 'mail',
        'sync_interval': 0,
      });
      final phonePrefs = await SharedPreferences.getInstance();
      final b = TestController(
        Repository(Directory('${dir.path}/phone')),
        phonePrefs,
        cloud,
      );
      await b.load();
      await b.sync();
      final att =
          (b.data.visible('task').single['attachments'] as List).single as Json;
      expect(await b.files.available(att), isFalse);
      final f = await b.fetchAttachment(att);
      expect(await f.length(), 5000);
      b.dispose();
    });

    test(
      'Файл уходит раньше записи; ошибка файла видна и повторяется',
      () async {
        final cloud = MemoryStore()..failBlobs = true;
        final a = TestController(
          Repository(Directory('${dir.path}/r')),
          prefs,
          cloud,
        );
        await a.load();
        await a.sync();
        cloud.log.clear();
        final src = File('${dir.path}/r.png')..writeAsBytesSync([9, 9, 9]);
        final meta = await a.files.import(src.path, kind: 'image');
        await a.save('note', {
          'id': 'n',
          'title': 'Схема',
          'attachments': [meta],
        });
        await a.sync();
        expect(a.syncError, contains('Не отправлено вложений: 1'));
        expect(
          cloud.snapshots,
          hasLength(1),
          reason: 'запись всё равно сохранена',
        );
        expect(a.uploadedBlobs, isEmpty);
        cloud.failBlobs = false;
        cloud.log.clear();
        await a.sync();
        expect(a.syncError, isNull);
        expect(cloud.blobs.keys, [meta['sha256']]);
        expect(cloud.log.first, 'blob');

        // Lost file in the cloud: "send again" re-checks and re-uploads.
        cloud.blobs.clear();
        await a.resendAttachments();
        expect(cloud.blobs.keys, [meta['sha256']]);
        a.dispose();
      },
    );
  });
}
