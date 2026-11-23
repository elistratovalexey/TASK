import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:path/path.dart' as p;
import 'attachments.dart';
import 'domain.dart';

/// Messages larger than this are turned into a task without attachments.
const maxMailBytes = 100 * 1024 * 1024;

/// IMAP folder where processed messages are moved (ASCII name: no
/// modified UTF-7 issues on Mail.ru / Yandex / Gmail).
const processedFolder = 'ProjectReminders-Done';

class IncomingMail {
  final int uid;
  final MimeMessage message;
  final bool truncated;
  IncomingMail(this.uid, this.message, {this.truncated = false});
}

/// Mailbox access. A separate interface so that tests can use a fake.
abstract class MailSource {
  Future<List<IncomingMail>> fetch({int max = 20});
  Future<void> markProcessed(int uid);
  Future<void> close();
}

class MailSettings {
  final String host;
  final int port;
  final String user;
  final String password;
  final String folder;
  final List<String> allowedSenders;
  const MailSettings({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    this.folder = 'INBOX',
    this.allowedSenders = const [],
  });
}

class ImapSource implements MailSource {
  final MailSettings settings;
  final ImapClient client = ImapClient(
    defaultResponseTimeout: const Duration(seconds: 60),
  );
  bool _connected = false;
  bool _folderReady = false;
  ImapSource(this.settings);

  Future<void> _open() async {
    if (_connected) return;
    try {
      await client.connectToServer(settings.host, settings.port);
      await client.login(settings.user, settings.password);
    } on ImapException catch (e) {
      throw StateError(
        'Не удалось войти в почту ${settings.user}: ${e.message ?? e}. '
        'Нужен пароль для внешнего приложения и включённый IMAP.',
      );
    } on SocketException catch (e) {
      throw StateError('Нет соединения с ${settings.host}: ${e.message}');
    }
    await client.selectMailboxByPath(settings.folder);
    _connected = true;
  }

  @override
  Future<List<IncomingMail>> fetch({int max = 20}) async {
    await _open();
    final search = await client.uidSearchMessages(searchCriteria: 'ALL');
    final uids = search.matchingSequence?.toList() ?? const <int>[];
    final out = <IncomingMail>[];
    for (final uid in uids.take(max)) {
      final seq = MessageSequence.fromIds([uid], isUid: true);
      final sizeResult = await client.uidFetchMessages(seq, '(RFC822.SIZE)');
      final size = sizeResult.messages.firstOrNull?.size ?? 0;
      final big = size > maxMailBytes;
      final result = await client.uidFetchMessages(
        seq,
        big ? '(BODY.PEEK[HEADER])' : '(BODY.PEEK[])',
      );
      final m = result.messages.firstOrNull;
      if (m != null) out.add(IncomingMail(uid, m, truncated: big));
    }
    return out;
  }

  Future<void> _ensureFolder() async {
    if (_folderReady) return;
    final boxes = await client.listMailboxes();
    if (!boxes.any(
      (b) => b.path == processedFolder || b.name == processedFolder,
    )) {
      await client.createMailbox(processedFolder);
    }
    await client.selectMailboxByPath(settings.folder);
    _folderReady = true;
  }

  @override
  Future<void> markProcessed(int uid) async {
    await _open();
    await _ensureFolder();
    final seq = MessageSequence.fromIds([uid], isUid: true);
    if (client.serverInfo.supportsMove) {
      await client.uidMove(seq, targetMailboxPath: processedFolder);
    } else {
      await client.uidCopy(seq, targetMailboxPath: processedFolder);
      await client.uidStore(seq, [
        MessageFlags.deleted,
      ], action: StoreAction.add);
      if (client.serverInfo.supportsUidPlus) {
        await client.uidExpunge(seq);
      } else {
        await client.expunge();
      }
    }
  }

  @override
  Future<void> close() async {
    if (!_connected) return;
    try {
      await client.logout();
    } catch (_) {}
    try {
      await client.disconnect();
    } catch (_) {}
  }
}

String senderOf(MimeMessage m) =>
    (m.from?.firstOrNull?.email ?? '').trim().toLowerCase();

/// Deterministic ID: the same letter never becomes two tasks, even if moving
/// it to the processed folder failed and it is read again.
String mailTaskId(MimeMessage m, int uid) {
  final key =
      m.decodeHeaderValue('message-id')?.trim() ??
      '$uid|${m.decodeHeaderValue('date')}|${m.decodeSubject()}|${senderOf(m)}';
  return 'mail-${sha256.convert(utf8.encode(key)).toString().substring(0, 32)}';
}

String cleanSubject(String? subject) {
  var s = (subject ?? '').trim();
  final prefix = RegExp(
    r'^(?:(?:fwd?|fw|re|пересл|пересылка|отв|ответ|aw|wg|tr)\.?\s*(?:\[\d+\])?\s*:\s*)',
    caseSensitive: false,
    unicode: true,
  );
  while (prefix.hasMatch(s)) {
    s = s.replaceFirst(prefix, '').trim();
  }
  return s;
}

String htmlToText(String html) {
  var s = html
      .replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</(p|div|tr|li|h[1-6])>', caseSensitive: false),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {
    '&nbsp;': ' ',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&laquo;': '«',
    '&raquo;': '»',
    '&mdash;': '—',
    '&ndash;': '–',
    '&amp;': '&',
  };
  entities.forEach((k, v) => s = s.replaceAll(k, v));
  return s
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _safeName(String name) {
  final n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return n.isEmpty ? 'file' : n;
}

/// Converts an e-mail into an inbox task. Attachments (including forwarded
/// letters attached as .eml and inline pictures with a file name) are copied
/// into the attachment store.
Future<Json> taskFromMail(
  IncomingMail mail,
  AttachmentStore files,
  Directory temp,
) async {
  final m = mail.message;
  final from = m.from?.firstOrNull;
  final sender = from == null
      ? 'неизвестный отправитель'
      : (from.personalName?.isNotEmpty == true
            ? '${from.personalName} <${from.email}>'
            : from.email);
  final date = m.decodeDate()?.toLocal();
  final subject = cleanSubject(m.decodeSubject());
  var body = mail.truncated
      ? ''
      : (m.decodeTextPlainPart() ??
            (m.decodeTextHtmlPart() == null
                ? ''
                : htmlToText(m.decodeTextHtmlPart()!)));
  body = body.trim();
  if (body.length > 20000) body = '${body.substring(0, 20000)}\n…';

  final attachments = <Json>[];
  final notes = StringBuffer('Из почты: $sender');
  if (date != null) {
    String two(int n) => n.toString().padLeft(2, '0');
    notes.write(
      ', ${two(date.day)}.${two(date.month)}.${date.year} ${two(date.hour)}:${two(date.minute)}',
    );
  }
  if (mail.truncated) {
    notes.write(
      '\nПисьмо больше ${maxMailBytes ~/ 1024 ~/ 1024} МБ: текст и вложения не загружены, '
      'откройте его в почте (папка $processedFolder).',
    );
  }
  if (!mail.truncated) {
    await temp.create(recursive: true);
    var n = 0;
    for (final part in m.allPartsFlat) {
      if (identical(part, m)) continue;
      final type = part.mediaType;
      if (type.isMultipart) continue;
      final disposition = part.getHeaderContentDisposition();
      final rfc822 = type.sub == MediaSubtype.messageRfc822;
      var name = part.decodeFileName();
      final isAttachment =
          disposition?.disposition == ContentDisposition.attachment ||
          (name != null && name.isNotEmpty) ||
          rfc822;
      if (!isAttachment) continue;
      final Uint8List? data = part.decodeContentBinary();
      if (data == null || data.isEmpty) continue;
      if (rfc822 && (name == null || name.isEmpty)) {
        String inner = '';
        try {
          inner = cleanSubject(MimeMessage.parseFromData(data).decodeSubject());
        } catch (_) {}
        name = '${inner.isEmpty ? 'Письмо' : inner}.eml';
      }
      final file = File(p.join(temp.path, 'mail_${uuid.v4()}.tmp'));
      try {
        await file.writeAsBytes(data, flush: true);
        attachments.add(
          await files.import(file.path, name: _safeName(name ?? 'file_${++n}')),
        );
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
  }
  if (body.isNotEmpty) notes.write('\n\n$body');
  return {
    'id': mailTaskId(m, mail.uid),
    'title': subject.isEmpty ? 'Письмо от $sender' : subject,
    'notes': notes.toString(),
    'projectId': null,
    'inbox': true,
    'estimate': 60,
    'priority': 1,
    'done': false,
    'due': null,
    'reminder': null,
    'repeat': 'none',
    'checklist': <Json>[],
    'attachments': attachments,
    'source': {
      'from': from?.email ?? '',
      'subject': m.decodeSubject() ?? '',
      if (date != null) 'receivedAt': date.toUtc().toIso8601String(),
    },
  };
}
