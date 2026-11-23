import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'cloud.dart';
import 'controller.dart';
import 'domain.dart';
import 'export.dart';
import 'updates.dart';
import 'version.dart';

/// Export of tasks to Excel: choose projects and statuses, then send by
/// e-mail or save the file.
class ExportDialog extends StatefulWidget {
  final AppController controller;
  const ExportDialog({super.key, required this.controller});
  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  AppController get c => widget.controller;
  late final tree = ProjectTree(c.data.visible('project'));
  late Set<String> projects = {...tree.byId.keys};
  Set<String> statuses = {'active', 'done', 'inbox'};
  late final to = TextEditingController(
    text: c.prefs.getString('export_to') ?? '',
  );
  late final smtpHost = TextEditingController(
    text: c.prefs.getString('smtp_host') ?? '',
  );
  late final smtpPort = TextEditingController(
    text: '${c.prefs.getInt('smtp_port') ?? 465}',
  );
  late final smtpUser = TextEditingController(
    text: c.prefs.getString('smtp_user') ?? '',
  );
  final smtpPassword = TextEditingController();
  bool working = false;
  String? status;

  @override
  void initState() {
    super.initState();
    if (to.text.isEmpty) {
      final senders = (c.prefs.getString('intake_senders') ?? '')
          .split(RegExp(r'[\s,;]+'))
          .where((e) => e.contains('@'));
      if (senders.isNotEmpty) {
        to.text = senders.first;
      } else {
        vault.read(key: 'mail_email').then((v) {
          if (mounted && v != null && to.text.isEmpty) {
            setState(() => to.text = v);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    for (final t in [to, smtpHost, smtpPort, smtpUser, smtpPassword]) {
      t.dispose();
    }
    super.dispose();
  }

  bool get allProjects => projects.length == tree.byId.length;

  int get count => exportRows(
    c.data,
    projects: allProjects ? null : projects,
    statuses: statuses,
  ).length;

  void toggle(String id, bool on) => setState(() {
    final ids = tree.subtree(id);
    on ? projects.addAll(ids) : projects.removeAll(ids);
  });

  Future<void> saveSmtp() async {
    await c.prefs.setString('smtp_host', smtpHost.text.trim());
    await c.prefs.setInt(
      'smtp_port',
      int.tryParse(smtpPort.text.trim()) ?? 465,
    );
    await c.prefs.setString('smtp_user', smtpUser.text.trim());
    if (smtpPassword.text.isNotEmpty) {
      await vault.write(key: 'smtp_password', value: smtpPassword.text);
      smtpPassword.clear();
    }
  }

  Future<void> send() async {
    setState(() {
      working = true;
      status = null;
    });
    await saveSmtp();
    final ok = await c.sendExport(
      to: to.text,
      projects: allProjects ? null : projects,
      statuses: statuses,
    );
    if (!mounted) return;
    setState(() {
      working = false;
      status = c.message;
    });
    if (ok) Navigator.pop(context);
  }

  Future<void> save() async {
    final bytes = c.exportXlsx(
      projects: allProjects ? null : projects,
      statuses: statuses,
    );
    final name = c.exportFileName();
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final dir = Directory('${c.files.directory.path}/export');
        await dir.create(recursive: true);
        final f = File('${dir.path}/$name');
        await f.writeAsBytes(bytes, flush: true);
        final r = await OpenFilex.open(
          f.path,
          type:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
        if (r.type != ResultType.done) {
          setState(
            () => status = 'Нет программы для открытия .xlsx: ${r.message}',
          );
        }
        return;
      }
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Excel', extensions: ['xlsx']),
        ],
      );
      if (location == null) return;
      var path = location.path;
      if (!path.toLowerCase().endsWith('.xlsx')) path = '$path.xlsx';
      await File(path).writeAsBytes(bytes, flush: true);
      setState(() => status = 'Сохранено: $path');
      await launchUrl(Uri.file(path));
    } catch (e) {
      setState(() => status = 'Не сохранено: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = count;
    return AlertDialog(
      title: const Text('Задачи в Excel'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Статусы',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final e in exportStatuses.entries)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(e.value),
                  value: statuses.contains(e.key),
                  onChanged: (v) => setState(
                    () => v! ? statuses.add(e.key) : statuses.remove(e.key),
                  ),
                ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Проекты',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () => projects = allProjects ? {} : {...tree.byId.keys},
                    ),
                    child: Text(allProjects ? 'Снять все' : 'Выбрать все'),
                  ),
                ],
              ),
              for (final e in tree.flatten())
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(left: 16.0 * e.depth),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    e.project['name'],
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: projects.contains(e.project['id']),
                  onChanged: (v) => toggle(e.project['id'], v!),
                ),
              const SizedBox(height: 8),
              Text(
                'Задач в файле: $n',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text(
                'Все поля задачи: проект, статус, сроки и их история, оценка и '
                'затраченное время, чек-лист, вложения (имена), заметки.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: to,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Отправить на адрес',
                ),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Настройки отправки'),
                subtitle: const Text(
                  'Пусто — используется ящик из «Задачи из почты»',
                  style: TextStyle(fontSize: 12),
                ),
                children: [
                  TextField(
                    controller: smtpHost,
                    decoration: const InputDecoration(
                      labelText: 'SMTP-сервер',
                      hintText: 'smtp.mail.ru',
                    ),
                  ),
                  TextField(
                    controller: smtpPort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Порт (465 — SSL, 587 — STARTTLS)',
                    ),
                  ),
                  TextField(
                    controller: smtpUser,
                    decoration: const InputDecoration(
                      labelText: 'Ящик отправителя',
                    ),
                  ),
                  TextField(
                    controller: smtpPassword,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Пароль для внешнего приложения',
                      helperText: 'Оставьте пустым, чтобы не менять',
                    ),
                  ),
                ],
              ),
              if (working) const LinearProgressIndicator(),
              if (status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(status!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        OutlinedButton(
          onPressed: working || n == 0 ? null : save,
          child: Text(Platform.isAndroid ? 'Открыть файл' : 'Сохранить файл'),
        ),
        FilledButton.icon(
          onPressed: working || n == 0 ? null : send,
          icon: const Icon(Icons.send),
          label: const Text('Отправить'),
        ),
      ],
    );
  }
}

/// Checking for a new version in the cloud, installing and publishing.
class UpdateDialog extends StatefulWidget {
  final AppController controller;
  const UpdateDialog({super.key, required this.controller});
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  AppController get c => widget.controller;
  UpdateManifest? manifest;
  bool checked = false;
  bool working = false;
  String? status;

  @override
  void initState() {
    super.initState();
    check();
  }

  Future<void> guard(Future<void> Function() f) async {
    setState(() {
      working = true;
      status = null;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) {
        setState(() => status = '$e'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> check() => guard(() async {
    final m = await c.checkUpdate();
    if (!mounted) return;
    setState(() {
      manifest = m;
      checked = true;
    });
  });

  Future<void> install() => guard(() async {
    final file = await c.downloadUpdate(manifest!);
    if (Platform.isAndroid) {
      final r = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (r.type != ResultType.done) {
        throw StateError(
          'Не удалось запустить установку: ${r.message}. Разрешите программе '
          '«Установку неизвестных приложений» в настройках Android.',
        );
      }
    } else if (!await launchUrl(Uri.file(file.path))) {
      throw StateError('Не удалось открыть ${file.path}');
    }
    if (mounted) {
      setState(
        () => status =
            'Установщик запущен. Подтвердите установку; '
            'данные программы сохранятся.',
      );
    }
  });

  Future<void> publish() async {
    final result = await showDialog<(File?, File?, String, String)>(
      context: context,
      builder: (_) => const PublishDialog(),
    );
    if (result == null) return;
    await guard(() async {
      final m = await c.publishUpdate(
        msix: result.$1,
        apk: result.$2,
        version: result.$3,
        notes: result.$4,
      );
      if (!mounted) return;
      setState(() {
        manifest = m;
        status =
            'Опубликована версия ${m.version}: '
            '${m.files.keys.map((k) => k == 'windows' ? 'Windows' : 'Android').join(', ')}.';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = manifest;
    final meta = m?.files[platformKey];
    return AlertDialog(
      title: const Text('Обновление программы'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Установлена версия $appVersion'),
              const SizedBox(height: 8),
              if (working) const LinearProgressIndicator(),
              if (checked && m == null)
                const Text('В облаке ещё нет опубликованных версий.'),
              if (m != null) ...[
                Text(
                  'В облаке: версия ${m.version}'
                  '${m.files.isEmpty ? '' : ' (${m.files.keys.map((k) => k == 'windows' ? 'Windows' : 'Android').join(', ')})'}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (m.notes.isNotEmpty) Text(m.notes),
                const SizedBox(height: 4),
                Text(
                  !m.newer
                      ? 'У вас последняя версия.'
                      : meta == null
                      ? 'Для этого устройства установщик не опубликован.'
                      : 'Доступно обновление: ${(meta['size'] / 1048576).toStringAsFixed(1)} МБ.',
                ),
              ],
              if (status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(status!),
                ),
              const SizedBox(height: 12),
              const Text(
                'Как выпустить обновление: соберите MSIX и APK на компьютере, '
                'затем здесь нажмите «Опубликовать версию» и выберите файлы. '
                'Остальные устройства найдут её по кнопке «Проверить обновление».',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        if (!Platform.isAndroid)
          OutlinedButton(
            onPressed: working ? null : publish,
            child: const Text('Опубликовать версию'),
          ),
        if (m != null && m.newer && meta != null)
          FilledButton(
            onPressed: working ? null : install,
            child: const Text('Скачать и установить'),
          )
        else
          FilledButton(
            onPressed: working ? null : check,
            child: const Text('Проверить снова'),
          ),
      ],
    );
  }
}

class PublishDialog extends StatefulWidget {
  const PublishDialog({super.key});
  @override
  State<PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<PublishDialog> {
  File? msix;
  File? apk;
  final version = TextEditingController();
  final notes = TextEditingController();
  String? error;

  @override
  void dispose() {
    version.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> pick(String ext) async {
    final f = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (f == null) return;
    final file = File(f.path);
    if (ext == 'msix') {
      final v = msixVersion(await file.readAsBytes());
      setState(() {
        msix = file;
        if (v != null) version.text = v;
      });
    } else {
      setState(() => apk = file);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Опубликовать версию'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Windows (.msix)'),
            subtitle: Text(
              msix?.path ??
                  'build\\windows\\x64\\runner\\Release\\project_reminders.msix',
            ),
            trailing: OutlinedButton(
              onPressed: () => pick('msix'),
              child: const Text('Выбрать'),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Android (.apk)'),
            subtitle: Text(
              apk?.path ?? 'build\\app\\outputs\\flutter-apk\\app-release.apk',
            ),
            trailing: OutlinedButton(
              onPressed: () => pick('apk'),
              child: const Text('Выбрать'),
            ),
          ),
          TextField(
            controller: version,
            decoration: const InputDecoration(
              labelText: 'Версия',
              helperText: 'Берётся из MSIX автоматически, например 1.0.1',
            ),
          ),
          TextField(
            controller: notes,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Что нового'),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          final v = version.text.trim();
          if (msix == null && apk == null) {
            setState(() => error = 'Выберите хотя бы один файл');
            return;
          }
          if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v)) {
            setState(() => error = 'Версия должна быть вида 1.0.1');
            return;
          }
          if (compareVersions(v, appVersion) < 0) {
            setState(
              () => error = 'Версия $v старше установленной $appVersion',
            );
            return;
          }
          Navigator.pop(context, (msix, apk, v, notes.text.trim()));
        },
        child: const Text('Опубликовать'),
      ),
    ],
  );
}
