import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:enough_mail/enough_mail.dart';
import 'domain.dart';
import 'planner.dart';
import 'people.dart';

/// Task statuses for export filtering.
const exportStatuses = {
  'active': 'Активные',
  'done': 'Выполненные',
  'inbox': 'Из почты (не разобраны)',
};

String taskStatus(Json t) => t['inbox'] == true
    ? 'inbox'
    : t['done'] == true
    ? 'done'
    : 'active';

/// One cell: text, number or date (stored as an Excel date).
sealed class Cell {
  const Cell();
}

class TextCell extends Cell {
  final String value;
  const TextCell(this.value);
}

class NumberCell extends Cell {
  final num value;
  const NumberCell(this.value);
}

class DateCell extends Cell {
  final DateTime value;
  const DateCell(this.value);
}

class EmptyCell extends Cell {
  const EmptyCell();
}

const _priorities = {0: 'Низкий', 1: 'Обычный', 2: 'Высокий'};
const _repeats = {
  'none': 'Нет',
  'daily': 'Ежедневно',
  'weekly': 'Еженедельно',
  'monthly': 'Ежемесячно',
};
const _colorNames = {
  'red': 'Красный',
  'orange': 'Оранжевый',
  'yellow': 'Жёлтый',
  'green': 'Зелёный',
  'blue': 'Синий',
  'purple': 'Фиолетовый',
  'grey': 'Серый',
};

String _date(String? iso) {
  if (iso == null) return '—';
  final d = DateTime.parse(iso).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

Cell _dateCell(String? iso) =>
    iso == null ? const EmptyCell() : DateCell(DateTime.parse(iso).toLocal());

const exportHeaders = [
  'ID',
  'Название',
  'Проект',
  'Задействованные',
  'Статус',
  'Просрочена',
  'Приоритет',
  'Срок',
  'Напоминание',
  'Повторение',
  'Оценка, ч',
  'Оценка',
  'Начало выполнения',
  'Окончание выполнения',
  'Затрачено, ч',
  'Затрачено',
  'Переносов срока',
  'История сроков',
  'Чек-лист, выполнено',
  'Чек-лист, всего',
  'Пункты чек-листа',
  'Вложения',
  'Цвет',
  'Заметки',
  'Источник (почта)',
  'На шкале',
  'Изменено',
];

/// Builds rows for tasks of the selected projects (null = all) and statuses.
List<List<Cell>> exportRows(
  Dataset data, {
  Set<String>? projects,
  Set<String> statuses = const {'active', 'done', 'inbox'},
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final tree = ProjectTree(data.visible('project'));
  final tasks =
      data.visible('task').where((t) {
        if (!statuses.contains(taskStatus(t))) return false;
        if (projects == null) return true;
        if (t['projectId'] == null) return taskStatus(t) == 'inbox';
        return projects.contains(t['projectId']);
      }).toList()..sort((a, b) {
        final pa = tree.byId.containsKey(a['projectId'])
            ? tree.path(a['projectId'])
            : '';
        final pb = tree.byId.containsKey(b['projectId'])
            ? tree.path(b['projectId'])
            : '';
        final c = pa.compareTo(pb);
        return c != 0
            ? c
            : (a['title'] as String).compareTo(b['title'] as String);
      });
  return [
    for (final t in tasks)
      () {
        final checklist = (t['checklist'] as List?) ?? const [];
        final history = (t['dueHistory'] as List?) ?? const [];
        final spent = spentTime(t);
        final estimate = estimateOf(t);
        final overdue =
            t['done'] != true &&
            t['due'] != null &&
            DateTime.parse(t['due']).isBefore(at);
        final versions = data.records['task:${t['id']}'] ?? const [];
        final changed = versions.isEmpty
            ? null
            : versions.last['updatedAt'] as String?;
        return <Cell>[
          TextCell(t['id']),
          TextCell(t['title']),
          TextCell(
            t['inbox'] == true
                ? 'Входящие (из почты)'
                : tree.byId.containsKey(t['projectId'])
                ? tree.path(t['projectId'])
                : '—',
          ),
          TextCell(involvedNames(data, t).join('\n')),
          TextCell(
            const {
              'active': 'Активна',
              'done': 'Выполнена',
              'inbox': 'Из почты',
            }[taskStatus(t)]!,
          ),
          TextCell(overdue ? 'Да' : 'Нет'),
          TextCell(_priorities[t['priority']] ?? 'Обычный'),
          _dateCell(t['due']),
          _dateCell(t['reminder']),
          TextCell(_repeats[t['repeat']] ?? 'Нет'),
          NumberCell(double.parse((estimate / 60).toStringAsFixed(2))),
          TextCell(estimateLabel(estimate)),
          _dateCell(t['startedAt']),
          _dateCell(t['finishedAt']),
          spent == null
              ? const EmptyCell()
              : NumberCell(
                  double.parse((spent.inMinutes / 60).toStringAsFixed(2)),
                ),
          TextCell(spent == null ? '' : durationLabel(spent)),
          NumberCell(history.where((h) => h['from'] != null).length),
          TextCell(
            history
                .map(
                  (h) =>
                      '${_date(h['at'])}: ${_date(h['from'])} → ${_date(h['to'])}'
                      '${h['reason'] == null ? '' : ' (${h['reason']})'}',
                )
                .join('\n'),
          ),
          NumberCell(checklist.where((c) => c['done'] == true).length),
          NumberCell(checklist.length),
          TextCell(
            checklist
                .map((c) => '${c['done'] == true ? '☑' : '☐'} ${c['text']}')
                .join('\n'),
          ),
          TextCell(
            ((t['attachments'] as List?) ?? const [])
                .map((a) => a['name'])
                .join('\n'),
          ),
          TextCell(_colorNames[t['color']] ?? ''),
          TextCell(t['notes'] ?? ''),
          TextCell(
            t['source'] == null
                ? ''
                : '${t['source']['from']}: ${t['source']['subject']}',
          ),
          TextCell(onTimeline(t) ? 'Да' : 'Нет'),
          _dateCell(changed),
        ];
      }(),
  ];
}

String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

String _column(int i) {
  var n = i + 1, s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/// Excel serial date (days since 1899-12-30) of a local time.
double excelDate(DateTime local) {
  final utc = DateTime.utc(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
  );
  return utc.difference(DateTime.utc(1899, 12, 30)).inSeconds / 86400;
}

/// Minimal valid .xlsx: one sheet, bold frozen header with filter,
/// dates in dd.mm.yyyy hh:mm, wrapped multi-line text.
Uint8List buildXlsx(
  List<String> headers,
  List<List<Cell>> rows, {
  String sheet = 'Задачи',
}) {
  String cell(int r, int c, Cell v) {
    final ref = '${_column(c)}${r + 1}';
    return switch (v) {
      TextCell(:final value) =>
        '<c r="$ref" t="inlineStr" s="${value.contains('\n') ? 3 : 0}"><is><t xml:space="preserve">${_xml(value)}</t></is></c>',
      NumberCell(:final value) => '<c r="$ref" s="4"><v>$value</v></c>',
      DateCell(:final value) =>
        '<c r="$ref" s="2"><v>${excelDate(value).toStringAsFixed(6)}</v></c>',
      EmptyCell() => '',
    };
  }

  final widths = [
    for (var c = 0; c < headers.length; c++)
      () {
        var w = headers[c].length + 2;
        for (final r in rows.take(500)) {
          final v = r[c];
          final len = switch (v) {
            TextCell(:final value) =>
              value.split('\n').fold(0, (m, l) => l.length > m ? l.length : m),
            DateCell() => 16,
            NumberCell(:final value) => '$value'.length,
            EmptyCell() => 0,
          };
          if (len + 2 > w) w = len + 2;
        }
        return w > 60 ? 60 : w;
      }(),
  ];
  final last = '${_column(headers.length - 1)}${rows.length + 1}';
  final sheetXml = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
    '<cols>',
  );
  for (var c = 0; c < widths.length; c++) {
    sheetXml.write(
      '<col min="${c + 1}" max="${c + 1}" width="${widths[c]}" customWidth="1"/>',
    );
  }
  sheetXml.write('</cols><sheetData><row r="1">');
  for (var c = 0; c < headers.length; c++) {
    sheetXml.write(
      '<c r="${_column(c)}1" t="inlineStr" s="1"><is><t>${_xml(headers[c])}</t></is></c>',
    );
  }
  sheetXml.write('</row>');
  for (var r = 0; r < rows.length; r++) {
    sheetXml.write('<row r="${r + 2}">');
    for (var c = 0; c < rows[r].length; c++) {
      sheetXml.write(cell(r + 1, c, rows[r][c]));
    }
    sheetXml.write('</row>');
  }
  sheetXml.write('</sheetData><autoFilter ref="A1:$last"/></worksheet>');

  const styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<numFmts count="1"><numFmt numFmtId="164" formatCode="dd.mm.yyyy hh:mm"/></numFmts>'
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
      '<fills count="3"><fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="5">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment vertical="top"/></xf>'
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"><alignment vertical="top" wrapText="1"/></xf>'
      '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"><alignment vertical="top"/></xf>'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment vertical="top"/></xf>'
      '</cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';
  final files = {
    '[Content_Types].xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>',
    '_rels/.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="${_xml(sheet)}" sheetId="1" r:id="rId1"/></sheets>'
        '<definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">\'${_xml(sheet)}\'!\$A\$1:\$${_column(headers.length - 1)}\$${rows.length + 1}</definedName></definedNames>'
        '</workbook>',
    'xl/_rels/workbook.xml.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'xl/styles.xml': styles,
    'xl/worksheets/sheet1.xml': sheetXml.toString(),
  };
  final archive = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encodeBytes(archive);
}

const xlsxMime =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

class SmtpSettings {
  final String host;
  final int port;
  final String user;
  final String password;
  const SmtpSettings(this.host, this.port, this.user, this.password);
}

/// A ready e-mail: raw RFC 5322 text plus envelope addresses.
class ExportMail {
  final String from;
  final String to;
  final String raw;
  const ExportMail(this.from, this.to, this.raw);
}

String _b64Lines(List<int> bytes) {
  final b = base64.encode(bytes);
  final out = StringBuffer();
  for (var i = 0; i < b.length; i += 76) {
    out.write(b.substring(i, i + 76 > b.length ? b.length : i + 76));
    out.write('\r\n');
  }
  return out.toString();
}

/// RFC 2047 encoded word (short chunks keep header lines < 78 chars).
String _word(String text) {
  final bytes = utf8.encode(text);
  if (bytes.every((b) => b >= 32 && b < 127) && !text.contains('"')) {
    return text;
  }
  final words = <String>[];
  var chunk = <int>[];
  for (final rune in text.runes) {
    final r = utf8.encode(String.fromCharCode(rune));
    if (chunk.length + r.length > 36) {
      words.add('=?utf-8?B?${base64.encode(chunk)}?=');
      chunk = [];
    }
    chunk.addAll(r);
  }
  if (chunk.isNotEmpty) words.add('=?utf-8?B?${base64.encode(chunk)}?=');
  return words.join('\r\n ');
}

/// RFC 2231 extended parameter value.
String _ext(String text) => utf8
    .encode(text)
    .map(
      (b) => RegExp(r'[A-Za-z0-9._-]').hasMatch(String.fromCharCode(b))
          ? String.fromCharCode(b)
          : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    )
    .join();

String _rfcDate(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final off = d.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final oh = off.inHours.abs().toString().padLeft(2, '0');
  final om = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
  String two(int n) => n.toString().padLeft(2, '0');
  return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]} ${d.year} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)} $sign$oh$om';
}

/// Builds a standard multipart/mixed e-mail with the file attached
/// (all non-ASCII text encoded, header lines kept short).
ExportMail buildExportMessage({
  required String from,
  required String to,
  required String subject,
  required String text,
  required String fileName,
  required Uint8List file,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final boundary =
      '=_pr_${at.microsecondsSinceEpoch.toRadixString(36)}_${file.length}';
  final id = '${at.microsecondsSinceEpoch}.${file.length}@project-reminders';
  final raw = StringBuffer()
    ..write('From: ${_word('Мои проекты')} <$from>\r\n')
    ..write('To: <$to>\r\n')
    ..write('Subject: ${_word(subject)}\r\n')
    ..write('Date: ${_rfcDate(at)}\r\n')
    ..write('Message-ID: <$id>\r\n')
    ..write('MIME-Version: 1.0\r\n')
    ..write('Content-Type: multipart/mixed;\r\n boundary="$boundary"\r\n')
    ..write('\r\n')
    ..write('--$boundary\r\n')
    ..write('Content-Type: text/plain; charset=utf-8\r\n')
    ..write('Content-Transfer-Encoding: base64\r\n\r\n')
    ..write(_b64Lines(utf8.encode(text)))
    ..write('--$boundary\r\n')
    ..write('Content-Type: $xlsxMime;\r\n name="${_word(fileName)}"\r\n')
    ..write('Content-Transfer-Encoding: base64\r\n')
    ..write(
      'Content-Disposition: attachment;\r\n'
      ' filename*=utf-8\'\'${_ext(fileName)};\r\n'
      ' size=${file.length}\r\n\r\n',
    )
    ..write(_b64Lines(file))
    ..write('--$boundary--\r\n');
  return ExportMail(from, to, raw.toString());
}

/// Sending interface (replaced by a fake in tests).
typedef MailSender = Future<void> Function(SmtpSettings s, ExportMail m);

Future<void> sendBySmtp(SmtpSettings s, ExportMail mail) async {
  final client = SmtpClient('project-reminders.local');
  try {
    await client.connectToServer(s.host, s.port, isSecure: s.port == 465);
    await client.ehlo();
    if (s.port != 465) await client.startTls();
    await client.authenticate(s.user, s.password, AuthMechanism.login);
    await client.sendMessageText(mail.raw, MailAddress(null, mail.from), [
      MailAddress(null, mail.to),
    ]);
  } on SmtpException catch (e) {
    throw StateError('Почтовый сервер ${s.host} отказал: ${e.message ?? e}');
  } finally {
    try {
      await client.quit();
    } catch (_) {}
  }
}
