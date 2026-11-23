import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:xml/xml.dart';

import 'domain.dart';

const driveScope = 'https://www.googleapis.com/auth/drive.appdata';
const vault = FlutterSecureStorage();

class CloudFailure implements Exception {
  final String message;
  CloudFailure(this.message);
  @override
  String toString() => message;
}

abstract class CloudStore {
  Future<List<String>> list();
  Future<Dataset> read(String id);
  Future<void> upload(Dataset data);
  Future<void> delete(String id);
  Future<bool> hasBlob(String sha);
  Future<void> putBlob(String sha, File file);
  Future<void> getBlob(String sha, File target);

  /// Small named JSON files next to the snapshots (e.g. update.json).
  Future<String?> readText(String name);
  Future<void> writeText(String name, String text);
  void close();
}

String checkedTextName(String name) {
  if (!RegExp(r'^[a-z_]{1,40}\.json$').hasMatch(name) ||
      name.startsWith('snapshot_')) {
    throw CloudFailure('Недопустимое имя файла: $name');
  }
  return name;
}

class SafeHttp {
  final http.Client client;
  SafeHttp([http.Client? client]) : client = client ?? http.Client();
  Future<http.Response> request(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final request = http.Request(method, url)..followRedirects = false;
    request.headers.addAll(headers);
    if (body != null) request.body = body;
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 10 * 1024 * 1024) {
        throw CloudFailure(
          'Ответ облака больше 10 МБ. Синхронизация остановлена.',
        );
      }
    }
    return http.Response.bytes(
      bytes,
      response.statusCode,
      headers: response.headers,
    );
  }

  /// Streams a file to the server (attachments can be large).
  Future<http.Response> sendFile(
    String method,
    Uri url,
    File file, {
    Map<String, String> headers = const {},
  }) async {
    final request = http.StreamedRequest(method, url)..followRedirects = false;
    request.headers.addAll(headers);
    request.contentLength = await file.length();
    unawaited(
      request.sink
          .addStream(file.openRead())
          .then((_) => request.sink.close(), onError: request.sink.addError),
    );
    final response = await client
        .send(request)
        .timeout(const Duration(minutes: 30));
    return http.Response.fromStream(response);
  }

  /// Streams a response body to a file. Returns the status code.
  Future<int> download(
    Uri url,
    File target, {
    Map<String, String> headers = const {},
    int limit = 1024 * 1024 * 1024,
  }) async {
    var current = url;
    late http.StreamedResponse response;
    for (var hop = 0; ; hop++) {
      final request = http.Request('GET', current)..followRedirects = false;
      // Credentials are sent only to the original host.
      if (current.host == url.host) request.headers.addAll(headers);
      response = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      final location = response.headers['location'];
      if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
          location == null ||
          hop >= 5) {
        break;
      }
      await response.stream.drain<void>();
      final next = current.resolve(location);
      if (next.scheme != 'https') {
        throw CloudFailure('Небезопасное перенаправление при скачивании.');
      }
      current = next;
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      return response.statusCode;
    }
    final sink = target.openWrite();
    var total = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(minutes: 2),
      )) {
        total += chunk.length;
        if (total > limit) throw CloudFailure('Файл в облаке слишком большой.');
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    return 200;
  }

  void close() => client.close();
}

void checkResponse(
  http.Response r,
  String action, [
  List<int> ok = const [200],
]) {
  if (ok.contains(r.statusCode)) return;
  if ([401, 403].contains(r.statusCode)) {
    throw CloudFailure(
      '$action: доступ запрещён (${r.statusCode}). '
      'Проверьте вход, разрешения и пароль приложения.',
    );
  }
  throw CloudFailure(
    '$action: HTTP ${r.statusCode}. Данные не заменены пустым файлом.',
  );
}

class MailStore implements CloudStore {
  static final root = Uri.parse(
    'https://webdav.cloud.mail.ru/ProjectReminders-v2/',
  );
  final SafeHttp httpClient;
  final String email;
  final String password;
  MailStore(this.email, this.password, {SafeHttp? httpClient})
    : httpClient = httpClient ?? SafeHttp();
  Map<String, String> get headers => {
    'Authorization': 'Basic ${base64Encode(utf8.encode('$email:$password'))}',
  };
  @override
  Future<List<String>> list() async {
    var response = await httpClient.request(
      'PROPFIND',
      root,
      headers: {...headers, 'Depth': '1'},
    );
    if (response.statusCode == 404) {
      final create = await httpClient.request('MKCOL', root, headers: headers);
      checkResponse(create, 'Создание папки Mail', [201, 405]);
      response = await httpClient.request(
        'PROPFIND',
        root,
        headers: {...headers, 'Depth': '1'},
      );
    }
    checkResponse(response, 'Список Mail', [207]);
    final xml = XmlDocument.parse(utf8.decode(response.bodyBytes));
    final ids = <String>{};
    for (final node in xml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'response',
    )) {
      final hrefs = node.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'href',
      );
      if (hrefs.isEmpty) continue;
      final uri = root.resolve(hrefs.first.innerText);
      if (uri.origin == root.origin &&
          uri.path == root.path.substring(0, root.path.length - 1) &&
          !uri.hasQuery &&
          !uri.hasFragment) {
        continue; // Some DAV servers omit the collection's trailing slash.
      }
      // Never forward Basic auth to a host/path supplied by an untrusted response.
      if (uri.scheme != root.scheme ||
          uri.host != root.host ||
          uri.port != root.port ||
          !uri.path.startsWith(root.path) ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw CloudFailure('Облако вернуло неожиданный адрес файла.');
      }
      final name = uri.path.substring(root.path.length);
      if (RegExp(r'^snapshot_[a-zA-Z0-9-]+\.json$').hasMatch(name)) {
        final statuses = node.descendants.whereType<XmlElement>().where(
          (e) => e.name.local == 'status',
        );
        if (!statuses.any((s) => s.innerText.contains(' 200 '))) {
          throw CloudFailure('Не удалось получить свойства снимка Mail.');
        }
        ids.add(uri.toString());
      }
    }
    if (ids.length > 1000) {
      throw CloudFailure(
        'Более 1000 снимков. Нужна архивация облачного журнала.',
      );
    }
    return ids.toList()..sort();
  }

  @override
  Future<Dataset> read(String id) async {
    final uri = Uri.parse(id);
    if (uri.origin != root.origin || !uri.path.startsWith(root.path)) {
      throw CloudFailure('Недопустимый адрес снимка');
    }
    final r = await httpClient.request('GET', uri, headers: headers);
    checkResponse(r, 'Чтение Mail');
    return Dataset.decode(utf8.decode(r.bodyBytes));
  }

  @override
  Future<void> upload(Dataset data) async {
    final uri = root.resolve('snapshot_${uuid.v4()}.json');
    final r = await httpClient.request(
      'PUT',
      uri,
      headers: {
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
        'If-None-Match': '*',
      },
      body: data.encode(),
    );
    checkResponse(r, 'Запись Mail', [200, 201, 204]);
  }

  Uri _checked(String id) {
    final uri = Uri.parse(id);
    if (uri.origin != root.origin ||
        !uri.path.startsWith(root.path) ||
        !RegExp(
          r'^snapshot_[a-zA-Z0-9-]+\.json$',
        ).hasMatch(uri.path.substring(root.path.length))) {
      throw CloudFailure('Недопустимый адрес снимка');
    }
    return uri;
  }

  @override
  Future<void> delete(String id) async {
    final r = await httpClient.request(
      'DELETE',
      _checked(id),
      headers: headers,
    );
    checkResponse(r, 'Удаление старого снимка Mail', [200, 204, 404]);
  }

  static final blobs = root.resolve('blobs/');
  bool _blobFolder = false;
  Uri _blob(String sha) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw CloudFailure('Некорректный идентификатор файла');
    }
    return blobs.resolve(sha);
  }

  /// PROPFIND instead of HEAD: Mail.ru WebDAV does not reliably support
  /// HEAD. Any unclear answer means "not there" — the file is then simply
  /// uploaded again, which is harmless for content-addressed files.
  Future<bool> _exists(Uri uri) async {
    final r = await httpClient.request(
      'PROPFIND',
      uri,
      headers: {...headers, 'Depth': '0'},
    );
    if ([401, 403].contains(r.statusCode)) {
      checkResponse(r, 'Проверка файла Mail');
    }
    return r.statusCode == 207 || r.statusCode == 200;
  }

  @override
  Future<bool> hasBlob(String sha) => _exists(_blob(sha));

  @override
  Future<String?> readText(String name) async {
    final r = await httpClient.request(
      'GET',
      root.resolve(checkedTextName(name)),
      headers: headers,
    );
    if (r.statusCode == 404) return null;
    checkResponse(r, 'Чтение $name из Mail');
    return utf8.decode(r.bodyBytes);
  }

  @override
  Future<void> writeText(String name, String text) async {
    final r = await httpClient.request(
      'PUT',
      root.resolve(checkedTextName(name)),
      headers: {...headers, 'Content-Type': 'application/json; charset=utf-8'},
      body: text,
    );
    checkResponse(r, 'Запись $name в Mail', [200, 201, 204]);
  }

  @override
  Future<void> putBlob(String sha, File file) async {
    if (!_blobFolder) {
      if (!await _exists(blobs)) {
        final r = await httpClient.request('MKCOL', blobs, headers: headers);
        checkResponse(r, 'Создание папки вложений Mail', [200, 201, 405]);
      }
      _blobFolder = true;
    }
    final r = await httpClient.sendFile(
      'PUT',
      _blob(sha),
      file,
      headers: {...headers, 'Content-Type': 'application/octet-stream'},
    );
    checkResponse(r, 'Загрузка вложения в Mail', [200, 201, 204]);
  }

  @override
  Future<void> getBlob(String sha, File target) async {
    final code = await httpClient.download(
      _blob(sha),
      target,
      headers: headers,
    );
    if (code == 404) throw CloudFailure('Файла ещё нет в облаке.');
    if (code != 200) {
      throw CloudFailure('Скачивание вложения Mail: HTTP $code');
    }
  }

  @override
  void close() => httpClient.close();
}

class DriveStore implements CloudStore {
  final String token;
  final SafeHttp httpClient;
  DriveStore(this.token, {SafeHttp? httpClient})
    : httpClient = httpClient ?? SafeHttp();
  Map<String, String> get headers => {'Authorization': 'Bearer $token'};
  @override
  Future<List<String>> list() async {
    final ids = <String>[];
    String? page;
    final visited = <String>{};
    do {
      final r = await httpClient.request(
        'GET',
        Uri.https('www.googleapis.com', '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'q': "trashed = false and name contains 'snapshot_'",
          'fields': 'nextPageToken,files(id,name)',
          'pageSize': '100',
          'pageToken': ?page,
        }),
        headers: headers,
      );
      checkResponse(r, 'Список Google Диска');
      final json = jsonDecode(utf8.decode(r.bodyBytes)) as Json;
      for (final f in json['files'] as List) {
        if (RegExp(r'^snapshot_[a-zA-Z0-9-]+\.json$').hasMatch(f['name'])) {
          ids.add(f['id'] as String);
        }
      }
      page = json['nextPageToken'] as String?;
      if (ids.length > 1000 || (page != null && !visited.add(page))) {
        throw CloudFailure(
          'Слишком большой или некорректный журнал Google Диска.',
        );
      }
    } while (page != null);
    return ids;
  }

  @override
  Future<Dataset> read(String id) async {
    final r = await httpClient.request(
      'GET',
      Uri.https('www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}),
      headers: headers,
    );
    checkResponse(r, 'Чтение Google Диска');
    return Dataset.decode(utf8.decode(r.bodyBytes));
  }

  @override
  Future<void> upload(Dataset data) async {
    final boundary = 'project_${uuid.v4()}';
    final metadata = jsonEncode({
      'name': 'snapshot_${uuid.v4()}.json',
      'parents': ['appDataFolder'],
      'mimeType': 'application/json',
    });
    final body =
        '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
        '${data.encode()}\r\n--$boundary--\r\n';
    final r = await httpClient.request(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'multipart',
        'fields': 'id',
      }),
      headers: {
        ...headers,
        'Content-Type': 'multipart/related; boundary=$boundary',
      },
      body: body,
    );
    checkResponse(r, 'Запись Google Диска', [200, 201]);
  }

  @override
  Future<void> delete(String id) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw CloudFailure('Некорректный ID файла Google');
    }
    final r = await httpClient.request(
      'DELETE',
      Uri.https('www.googleapis.com', '/drive/v3/files/$id'),
      headers: headers,
    );
    checkResponse(r, 'Удаление старого снимка Google', [200, 204, 404]);
  }

  Future<String?> _blobId(String sha) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw CloudFailure('Некорректный идентификатор файла');
    }
    final r = await httpClient.request(
      'GET',
      Uri.https('www.googleapis.com', '/drive/v3/files', {
        'spaces': 'appDataFolder',
        'q': "trashed = false and name = 'blob_$sha'",
        'fields': 'files(id)',
        'pageSize': '1',
      }),
      headers: headers,
    );
    checkResponse(r, 'Поиск вложения на Google Диске');
    final files =
        (jsonDecode(utf8.decode(r.bodyBytes)) as Json)['files'] as List;
    return files.isEmpty ? null : files.first['id'] as String;
  }

  @override
  Future<bool> hasBlob(String sha) async => await _blobId(sha) != null;

  Future<String?> _namedId(String name) async {
    final r = await httpClient.request(
      'GET',
      Uri.https('www.googleapis.com', '/drive/v3/files', {
        'spaces': 'appDataFolder',
        'q': "trashed = false and name = '${checkedTextName(name)}'",
        'fields': 'files(id)',
        'pageSize': '1',
      }),
      headers: headers,
    );
    checkResponse(r, 'Поиск $name на Google Диске');
    final files =
        (jsonDecode(utf8.decode(r.bodyBytes)) as Json)['files'] as List;
    return files.isEmpty ? null : files.first['id'] as String;
  }

  @override
  Future<String?> readText(String name) async {
    final id = await _namedId(name);
    if (id == null) return null;
    final r = await httpClient.request(
      'GET',
      Uri.https('www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}),
      headers: headers,
    );
    checkResponse(r, 'Чтение $name с Google Диска');
    return utf8.decode(r.bodyBytes);
  }

  @override
  Future<void> writeText(String name, String text) async {
    final id = await _namedId(name);
    if (id != null) {
      final r = await httpClient.request(
        'PATCH',
        Uri.https('www.googleapis.com', '/upload/drive/v3/files/$id', {
          'uploadType': 'media',
        }),
        headers: {
          ...headers,
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: text,
      );
      checkResponse(r, 'Запись $name на Google Диск');
      return;
    }
    final boundary = 'project_${uuid.v4()}';
    final metadata = jsonEncode({
      'name': name,
      'parents': ['appDataFolder'],
      'mimeType': 'application/json',
    });
    final r = await httpClient.request(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'multipart',
        'fields': 'id',
      }),
      headers: {
        ...headers,
        'Content-Type': 'multipart/related; boundary=$boundary',
      },
      body:
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
          '$metadata\r\n--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
          '$text\r\n--$boundary--\r\n',
    );
    checkResponse(r, 'Запись $name на Google Диск', [200, 201]);
  }

  @override
  Future<void> putBlob(String sha, File file) async {
    final start = await httpClient.request(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'resumable',
      }),
      headers: {
        ...headers,
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'application/octet-stream',
      },
      body: jsonEncode({
        'name': 'blob_$sha',
        'parents': ['appDataFolder'],
      }),
    );
    checkResponse(start, 'Начало загрузки вложения Google');
    final location = Uri.tryParse(start.headers['location'] ?? '');
    if (location == null || location.host != 'www.googleapis.com') {
      throw CloudFailure('Google не вернул адрес загрузки.');
    }
    final r = await httpClient.sendFile(
      'PUT',
      location,
      file,
      headers: {...headers, 'Content-Type': 'application/octet-stream'},
    );
    checkResponse(r, 'Загрузка вложения на Google Диск', [200, 201]);
  }

  @override
  Future<void> getBlob(String sha, File target) async {
    final id = await _blobId(sha);
    if (id == null) throw CloudFailure('Файла ещё нет в облаке.');
    final code = await httpClient.download(
      Uri.https('www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}),
      target,
      headers: headers,
    );
    if (code != 200) {
      throw CloudFailure('Скачивание вложения Google: HTTP $code');
    }
  }

  @override
  void close() => httpClient.close();
}

// Download every snapshot before saving or uploading anything. A failed read
// never masquerades as an empty cloud. Immutable uploads avoid cross-device
// read/modify/write races without relying on provider-specific locking.
Future<Dataset> downloadMerged(CloudStore cloud, Dataset local) async {
  var merged = local.copy();
  for (final id in await cloud.list()) {
    merged = merged.merge(await cloud.read(id));
  }
  return merged;
}

class GoogleAuth {
  final String desktopClient;
  final String androidServerClient;
  GoogleAuth({required this.desktopClient, required this.androidServerClient});
  GoogleSignIn get android => GoogleSignIn(
    scopes: [driveScope],
    serverClientId: androidServerClient.isEmpty ? null : androidServerClient,
  );

  Future<String> token({bool interactive = true}) async {
    if (Platform.isAndroid) {
      final signIn = android;
      final account =
          await signIn.signInSilently() ??
          (interactive ? await signIn.signIn() : null);
      if (account == null && !interactive) {
        throw CloudFailure(
          'Нужен вход Google: нажмите кнопку синхронизации вручную.',
        );
      }
      if (account == null) throw CloudFailure('Вход Google отменён.');
      final auth = await account.authentication;
      if (auth.accessToken == null) {
        throw CloudFailure('Google не выдал токен доступа.');
      }
      return auth.accessToken!;
    }
    if (!Platform.isWindows) {
      throw CloudFailure('Вход поддерживается на Windows и Android.');
    }
    if (!desktopClient.endsWith('.apps.googleusercontent.com')) {
      throw CloudFailure('Укажите Desktop OAuth Client ID в настройках.');
    }
    final stored = await vault.read(key: 'google_refresh');
    final secret = await vault.read(key: 'google_desktop_secret');
    final network = SafeHttp();
    try {
      if (stored != null) {
        final refresh = jsonDecode(stored) as Json;
        if (refresh['clientId'] == desktopClient) {
          final r = await network.request(
            'POST',
            Uri.parse('https://oauth2.googleapis.com/token'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: Uri(
              queryParameters: {
                'client_id': desktopClient,
                'refresh_token': refresh['token'],
                'grant_type': 'refresh_token',
                if (secret != null && secret.isNotEmpty)
                  'client_secret': secret,
              },
            ).query,
          );
          if (r.statusCode == 200) {
            return (jsonDecode(r.body) as Json)['access_token'];
          }
          if (r.statusCode != 400 ||
              (jsonDecode(r.body) as Json)['error'] != 'invalid_grant') {
            checkResponse(r, 'Обновление доступа Google');
          }
          await vault.delete(key: 'google_refresh');
        }
      }
      if (!interactive) {
        throw CloudFailure(
          'Нужен вход Google: нажмите кнопку синхронизации вручную.',
        );
      }
      return await _interactive(network, secret);
    } finally {
      network.close();
    }
  }

  Future<String> _interactive(SafeHttp network, String? secret) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    String nonce() => base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final state = nonce();
    final verifier = nonce();
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final redirect = 'http://127.0.0.1:${server.port}/oauth2redirect';
    final code = Completer<String>();
    final subscription = server.listen((r) async {
      if (r.method != 'GET' ||
          r.uri.path != '/oauth2redirect' ||
          r.uri.queryParameters['state'] != state) {
        r.response.statusCode = 400;
        await r.response.close();
        return;
      }
      final value = r.uri.queryParameters['code'];
      r.response.headers.contentType = ContentType.text;
      r.response.write(
        value == null
            ? 'Вход отменён. Вернитесь в приложение.'
            : 'Вход завершён. Вернитесь в «Мои проекты».',
      );
      await r.response.close();
      if (!code.isCompleted) {
        if (value == null) {
          code.completeError(CloudFailure('Вход Google отменён.'));
        } else {
          code.complete(value);
        }
      }
    });
    // Attach timeout/error handling before opening the browser.
    final pending = code.future
        .timeout(const Duration(minutes: 3))
        .then<({String? value, Object? error})>(
          (v) => (value: v, error: null),
          onError: (Object e, StackTrace _) => (value: null, error: e),
        );
    try {
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': desktopClient,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': driveScope,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
      });
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (!code.isCompleted) code.complete('');
        throw CloudFailure('Не удалось открыть системный браузер.');
      }
      final response = await pending;
      if (response.error != null) {
        throw CloudFailure('Вход Google отменён или время ожидания истекло.');
      }
      final receivedCode = response.value!;
      final r = await network.request(
        'POST',
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: Uri(
          queryParameters: {
            'client_id': desktopClient,
            'code': receivedCode,
            'redirect_uri': redirect,
            'grant_type': 'authorization_code',
            'code_verifier': verifier,
            if (secret != null && secret.isNotEmpty) 'client_secret': secret,
          },
        ).query,
      );
      checkResponse(r, 'Вход Google');
      final value = jsonDecode(r.body) as Json;
      if (value['access_token'] is! String) {
        throw CloudFailure('Не получен токен Google.');
      }
      if (value['refresh_token'] is String) {
        await vault.write(
          key: 'google_refresh',
          value: jsonEncode({
            'clientId': desktopClient,
            'token': value['refresh_token'],
          }),
        );
      }
      return value['access_token'];
    } finally {
      if (!code.isCompleted) code.complete('');
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  Future<void> disconnect() async {
    await vault.delete(key: 'google_refresh');
    if (Platform.isAndroid) await android.signOut();
  }
}
