import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:project_reminders/cloud.dart';
import 'package:project_reminders/domain.dart';

import 'domain_test.dart' show base, task;

void main() {
  String xml(String href) =>
      '''<d:multistatus xmlns:d="DAV:"><d:response>
    <d:href>$href</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat></d:response></d:multistatus>''';
  test('Mail получает снимки через PROPFIND и GET', () async {
    final b = base();
    final calls = <String>[];
    final mail = MailStore(
      'test@example.invalid',
      'fake',
      httpClient: SafeHttp(
        MockClient((r) async {
          calls.add(r.method);
          if (r.method == 'PROPFIND') {
            return http.Response(
              xml('/ProjectReminders-v2/snapshot_abc.json'),
              207,
            );
          }
          return http.Response(
            b.encode(),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    final merged = await downloadMerged(mail, Dataset());
    expect(merged.encode(), b.encode());
    expect(calls, ['PROPFIND', 'GET']);
    mail.close();
  });
  test('Mail не считает 401 пустым облаком', () async {
    final mail = MailStore(
      'x',
      'fake',
      httpClient: SafeHttp(MockClient((_) async => http.Response('', 401))),
    );
    await expectLater(mail.list(), throwsA(isA<CloudFailure>()));
    mail.close();
  });
  test('Mail не отправляет пароль по чужому href', () async {
    final mail = MailStore(
      'x',
      'fake',
      httpClient: SafeHttp(
        MockClient(
          (_) async => http.Response(
            xml('https://evil.invalid/ProjectReminders-v2/snapshot_a.json'),
            207,
          ),
        ),
      ),
    );
    await expectLater(mail.list(), throwsA(isA<CloudFailure>()));
    mail.close();
  });
  test('Mail создаёт папку только при 404', () async {
    final methods = <String>[];
    final mail = MailStore(
      'x',
      'fake',
      httpClient: SafeHttp(
        MockClient((r) async {
          methods.add(r.method);
          if (methods.length == 1) return http.Response('', 404);
          if (r.method == 'MKCOL') return http.Response('', 201);
          return http.Response(xml('/ProjectReminders-v2/'), 207);
        }),
      ),
    );
    expect(await mail.list(), isEmpty);
    expect(methods, ['PROPFIND', 'MKCOL', 'PROPFIND']);
    mail.close();
  });
  test('Mail пишет новый снимок, не перезаписывает общий файл', () async {
    final urls = <Uri>[];
    final mail = MailStore(
      'x',
      'fake',
      httpClient: SafeHttp(
        MockClient((r) async {
          expect(r.method, 'PUT');
          expect(r.headers['If-None-Match'] ?? r.headers['if-none-match'], '*');
          urls.add(r.url);
          Dataset.decode(r.body);
          return http.Response('', 201);
        }),
      ),
    );
    await mail.upload(base());
    await mail.upload(base());
    expect(urls[0], isNot(urls[1]));
    mail.close();
  });
  test('Drive читает все страницы и только пространство приложения', () async {
    var calls = 0;
    final drive = DriveStore(
      'fake',
      httpClient: SafeHttp(
        MockClient((r) async {
          calls++;
          expect(r.url.queryParameters['spaces'], 'appDataFolder');
          return http.Response(
            jsonEncode(
              calls == 1
                  ? {
                      'files': [
                        {'id': '1', 'name': 'snapshot_a.json'},
                      ],
                      'nextPageToken': 'page2',
                    }
                  : {
                      'files': [
                        {'id': '2', 'name': 'snapshot_b.json'},
                      ],
                    },
            ),
            200,
          );
        }),
      ),
    );
    expect(await drive.list(), ['1', '2']);
    expect(calls, 2);
    drive.close();
  });
  test('Drive загружает multipart в appDataFolder', () async {
    final drive = DriveStore(
      'fake',
      httpClient: SafeHttp(
        MockClient((r) async {
          expect(r.method, 'POST');
          expect(r.url.path, '/upload/drive/v3/files');
          expect(r.body, contains('"parents":["appDataFolder"]'));
          expect(r.body, contains('"version":2'));
          return http.Response('{"id":"created"}', 200);
        }),
      ),
    );
    await drive.upload(base());
    drive.close();
  });
  test('Повреждённый удалённый файл не меняет локальные данные', () async {
    final local = base();
    final before = local.encode();
    final drive = DriveStore(
      'fake',
      httpClient: SafeHttp(
        MockClient((r) async {
          if (r.url.queryParameters['alt'] == 'media') {
            return http.Response('broken', 200);
          }
          return http.Response(
            '{"files":[{"id":"1","name":"snapshot_a.json"}]}',
            200,
          );
        }),
      ),
    );
    await expectLater(downloadMerged(drive, local), throwsFormatException);
    expect(local.encode(), before);
    drive.close();
  });
  test('Конкурентные снимки объединяются без потери изменений', () async {
    final b = base();
    final a = b.copy()..write('task', {...task(), 'title': 'ПК'}, 'A');
    final phone = b.copy()..write('task', {...task(), 'title': 'Телефон'}, 'B');
    final drive = DriveStore(
      'fake',
      httpClient: SafeHttp(
        MockClient((r) async {
          if (r.url.queryParameters['alt'] == 'media') {
            return http.Response(
              phone.encode(),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            '{"files":[{"id":"1","name":"snapshot_a.json"}]}',
            200,
          );
        }),
      ),
    );
    expect((await downloadMerged(drive, a)).conflicts, ['task:t']);
    drive.close();
  });
  test(
    'Mail: вложение — MKCOL и PUT в blobs, чужой адрес не удаляется',
    () async {
      final calls = <String>[];
      final mail = MailStore(
        'x',
        'fake',
        httpClient: SafeHttp(
          MockClient((r) async {
            calls.add('${r.method} ${r.url.path}');
            return http.Response('', r.method == 'MKCOL' ? 405 : 201);
          }),
        ),
      );
      final dir = await Directory.systemTemp.createTemp('blob_');
      final f = File('${dir.path}/a')..writeAsStringSync('abc');
      final sha = 'a' * 64;
      await mail.putBlob(sha, f);
      expect(calls, [
        'PROPFIND /ProjectReminders-v2/blobs/',
        'MKCOL /ProjectReminders-v2/blobs/',
        'PUT /ProjectReminders-v2/blobs/$sha',
      ]);
      await expectLater(
        mail.delete('https://evil.invalid/ProjectReminders-v2/snapshot_a.json'),
        throwsA(isA<CloudFailure>()),
      );
      await expectLater(
        mail.delete(
          'https://webdav.cloud.mail.ru/ProjectReminders-v2/blobs/$sha',
        ),
        throwsA(isA<CloudFailure>()),
      );
      await dir.delete(recursive: true);
      mail.close();
    },
  );
  test(
    'Скачивание идёт по перенаправлению без передачи пароля чужому узлу',
    () async {
      final seen = <String>[];
      final h = SafeHttp(
        MockClient((r) async {
          seen.add('${r.url.host} ${r.headers['Authorization'] ?? '-'}');
          if (r.url.host == 'webdav.cloud.mail.ru') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://cdn.example/file'},
            );
          }
          return http.Response('abc', 200);
        }),
      );
      final dir = await Directory.systemTemp.createTemp('redir_');
      final f = File('${dir.path}/x');
      final code = await h.download(
        Uri.parse('https://webdav.cloud.mail.ru/ProjectReminders-v2/blobs/x'),
        f,
        headers: {'Authorization': 'Basic secret'},
      );
      expect(code, 200);
      expect(f.readAsStringSync(), 'abc');
      expect(seen, ['webdav.cloud.mail.ru Basic secret', 'cdn.example -']);
      await dir.delete(recursive: true);
    },
  );
}
