import 'package:flutter/material.dart';
import 'cloud.dart';
import 'controller.dart';

/// Popular IMAP servers. Every one of them needs an app password.
const imapPresets = {
  'Mail.ru': ('imap.mail.ru', 993),
  'Яндекс': ('imap.yandex.ru', 993),
  'Gmail': ('imap.gmail.com', 993),
};

class MailIntakePage extends StatefulWidget {
  final AppController controller;
  const MailIntakePage({super.key, required this.controller});
  @override
  State<MailIntakePage> createState() => _MailIntakePageState();
}

class _MailIntakePageState extends State<MailIntakePage> {
  AppController get c => widget.controller;
  late bool enabled = c.intakeEnabled;
  late final host = TextEditingController(
    text: c.prefs.getString('intake_host') ?? 'imap.mail.ru',
  );
  late final port = TextEditingController(
    text: '${c.prefs.getInt('intake_port') ?? 993}',
  );
  late final user = TextEditingController(
    text: c.prefs.getString('intake_user') ?? '',
  );
  final password = TextEditingController();
  late final folder = TextEditingController(
    text: c.prefs.getString('intake_folder') ?? 'INBOX',
  );
  late final senders = TextEditingController(
    text: c.prefs.getString('intake_senders') ?? '',
  );
  bool hasPassword = false;
  bool working = false;
  String? status;

  @override
  void initState() {
    super.initState();
    () async {
      final saved = await vault.read(key: 'intake_password');
      final cloudEmail = await vault.read(key: 'mail_email');
      if (!mounted) return;
      setState(() {
        hasPassword = saved != null && saved.isNotEmpty;
        if (senders.text.isEmpty && cloudEmail != null) {
          senders.text = cloudEmail;
        }
      });
    }();
  }

  @override
  void dispose() {
    for (final t in [host, port, user, password, folder, senders]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<bool> save() async {
    final p = int.tryParse(port.text.trim());
    if (p == null || p <= 0 || p > 65535) {
      setState(() => status = 'Некорректный порт');
      return false;
    }
    if (enabled && !user.text.contains('@')) {
      setState(() => status = 'Укажите адрес почтового ящика для задач');
      return false;
    }
    final ok = await Future.wait([
      c.prefs.setBool('intake_enabled', enabled),
      c.prefs.setString('intake_host', host.text.trim()),
      c.prefs.setInt('intake_port', p),
      c.prefs.setString('intake_user', user.text.trim()),
      c.prefs.setString(
        'intake_folder',
        folder.text.trim().isEmpty ? 'INBOX' : folder.text.trim(),
      ),
      c.prefs.setString('intake_senders', senders.text.trim()),
    ]);
    if (ok.contains(false)) {
      setState(() => status = 'Настройки не сохранены');
      return false;
    }
    if (password.text.isNotEmpty) {
      await vault.write(key: 'intake_password', value: password.text);
      password.clear();
      hasPassword = true;
    }
    c.configureAutoSync();
    return true;
  }

  Future<void> check() async {
    setState(() {
      working = true;
      status = null;
    });
    try {
      if (!await save()) return;
      if (!enabled) {
        setState(
          () => status = 'Сохранено. Приём почты на этом устройстве выключен.',
        );
        return;
      }
      final n = await c.checkMail(silent: false);
      if (!mounted) return;
      setState(
        () => status = c.mailError != null
            ? 'Ошибка: ${c.mailError}'
            : n > 0
            ? 'Создано задач: $n. Они на главном экране в блоке «Из почты».'
            : (c.message ?? 'Подключение работает. Новых писем нет.'),
      );
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Задачи из почты')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Перешлите письмо на отдельный почтовый ящик — программа сама создаст '
          'задачу: тема письма станет названием, текст — заметками, а вложенные '
          'файлы — вложениями задачи. Затем на главном экране появится блок '
          '«Из почты», где вы выберете проект, срок и приоритет.\n\n'
          'Заведите для этого НОВЫЙ ящик (например, zadachi.ваше_имя@mail.ru): '
          'программа обрабатывает каждое письмо от разрешённых отправителей и '
          'переносит его в папку ProjectReminders-Done. Письма от других '
          'адресов не трогаются.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Получать задачи из почты на этом устройстве'),
          subtitle: const Text(
            'Включите только на одном устройстве (например, на компьютере). '
            'Задачи попадут на остальные через синхронизацию. Почта '
            'проверяется, пока программа открыта: при запуске, при каждой '
            'синхронизации и не реже раза в 15 минут.',
          ),
          value: enabled,
          onChanged: working ? null : (v) => setState(() => enabled = v),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final e in imapPresets.entries)
              ActionChip(
                label: Text(e.key),
                onPressed: () => setState(() {
                  host.text = e.value.$1;
                  port.text = '${e.value.$2}';
                }),
              ),
          ],
        ),
        TextField(
          controller: host,
          decoration: const InputDecoration(labelText: 'IMAP-сервер'),
        ),
        TextField(
          controller: port,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Порт (SSL)'),
        ),
        TextField(
          controller: user,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Адрес ящика для задач',
            helperText: 'На этот адрес вы будете пересылать письма',
          ),
        ),
        TextField(
          controller: password,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Пароль для внешнего приложения',
            helperText: hasPassword
                ? 'Пароль сохранён. Введите новый, чтобы заменить.'
                : 'Mail.ru: Настройки → Безопасность → Пароли для внешних '
                      'приложений (доступ к почте по IMAP).',
            helperMaxLines: 3,
          ),
        ),
        TextField(
          controller: senders,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Разрешённые отправители',
            helperText:
                'Ваши адреса, с которых вы пересылаете письма, через запятую. '
                'Только их письма становятся задачами.',
            helperMaxLines: 3,
          ),
        ),
        TextField(
          controller: folder,
          decoration: const InputDecoration(
            labelText: 'Папка с входящими',
            helperText: 'Обычно INBOX',
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: working ? null : check,
              icon: const Icon(Icons.mark_email_read_outlined),
              label: const Text('Сохранить и проверить почту'),
            ),
          ],
        ),
        if (working) const LinearProgressIndicator(),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(status!),
          ),
      ],
    ),
  );
}
