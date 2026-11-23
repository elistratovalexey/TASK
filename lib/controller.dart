import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachments.dart';
import 'cloud.dart';
import 'mail_intake.dart';
import 'export.dart';
import 'planner.dart';
import 'shopping_model.dart';
import 'updates.dart';
import 'version.dart';
import 'domain.dart';
import 'reminders.dart';
import 'storage.dart';

/// Auto-sync interval options in minutes (0 = only after changes / on start).
const syncIntervals = {
  0: 'Только при запуске и после изменений',
  5: 'Каждые 5 минут',
  15: 'Каждые 15 минут',
  60: 'Каждый час',
};

class AppController extends ChangeNotifier {
  final Repository repository;
  final SharedPreferences prefs;
  final bool notifications;
  late final Reminders reminders = Reminders(prefs);
  late final AttachmentStore files = AttachmentStore(repository.directory);
  Dataset data = Dataset();
  String device = '';
  bool ready = false;
  bool busy = false;
  String? fatal;
  String? warning;
  String? message;

  // Synchronization state, shown in the app bar.
  bool syncing = false;
  String? syncError;
  String? syncProgress;
  Timer? _debounce;
  Timer? _periodic;
  Future<void> _lock = Future.value();
  final Set<String> downloading = {};

  AppController(this.repository, this.prefs, {this.notifications = true});

  String get provider => prefs.getString('provider') ?? 'none';
  bool get cloudOn => provider != 'none';

  // E-mail intake: letters sent (forwarded) to a mailbox become inbox tasks.
  // Enable it on ONE device only, otherwise two devices may create the same
  // task at the same moment and it would show up as a version conflict.
  bool get intakeEnabled => prefs.getBool('intake_enabled') ?? false;
  String? mailError;
  int mailReceived = 0;
  bool checkingMail = false;
  MailSource Function(MailSettings) mailSource = ImapSource.new;

  List<Json> get inboxTasks => data
      .visible('task')
      .where((t) => t['inbox'] == true && !data.conflicted('task', t['id']))
      .toList();
  bool get autoSync => prefs.getBool('auto_sync') ?? true;
  int get syncInterval => prefs.getInt('sync_interval') ?? 15;

  /// Serializes all writes to the local dataset (user edits and sync merge).
  Future<T> locked<T>(Future<T> Function() action) {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  Future<void> load() async {
    try {
      device = prefs.getString('device_id_v2') ?? uuid.v4();
      if (!await prefs.setString('device_id_v2', device)) {
        throw StateError('Не сохранён ID устройства');
      }
      data = await repository.load(prefs);
      ready = true;
      await schedule();
      configureAutoSync();
      if ((autoSync && cloudOn) || intakeEnabled) {
        unawaited(sync(silent: true));
      }
    } catch (e) {
      fatal =
          'Не удалось прочитать данные. Запись заблокирована.\n$e\n'
          'Папка данных: ${repository.directory.path}';
    }
    notifyListeners();
  }

  void configureAutoSync() {
    _periodic?.cancel();
    _periodic = null;
    final cloud = autoSync && cloudOn && syncInterval > 0;
    if (!cloud && !intakeEnabled) return;
    _periodic = Timer.periodic(
      Duration(minutes: cloud ? syncInterval : 15),
      (_) => sync(silent: true),
    );
  }

  /// Called after every local change: sync a few seconds later, so that a
  /// series of quick edits is sent as one snapshot.
  void _changed() {
    if (!autoSync || provider == 'none') return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 10), () => sync(silent: true));
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    super.dispose();
  }

  Future<void> schedule() async {
    if (!notifications) return;
    try {
      warning = await reminders.reconcile(data);
    } catch (e, stack) {
      debugPrint('Ошибка обновления напоминаний: $e');
      debugPrintStack(stackTrace: stack);
      warning = 'Не удалось обновить напоминания.\nПричина: $e';
    }
  }

  Future<bool> run(Future<void> Function() operation) async {
    if (busy || !ready) return false;
    busy = true;
    message = null;
    notifyListeners();
    try {
      await operation();
      return true;
    } catch (e) {
      message = 'Операция не завершена: $e';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> persist(Dataset value, {bool fromSync = false}) async {
    await repository.save(value);
    data = value;
    await schedule();
    notifyListeners();
    if (!fromSync) _changed();
  }

  /// Applies a change to the current dataset under the write lock.
  Future<void> mutate(void Function(Dataset d) change) => locked(() async {
    final updated = data.copy();
    change(updated);
    await persist(updated);
  });

  Future<bool> save(String kind, Json value, {bool deleted = false}) =>
      run(() async {
        if (data.conflicted(kind, value['id'])) {
          throw StateError('Сначала выберите версию в разделе «Конфликты».');
        }
        await mutate((d) => d.write(kind, value, device, deleted: deleted));
      });

  /// Deletes a project together with its subprojects and their tasks.
  Future<bool> deleteProject(String id) => run(() async {
    final tree = ProjectTree(data.visible('project'));
    final ids = tree.subtree(id);
    if (ids.any((p) => data.conflicted('project', p))) {
      throw StateError('Сначала разрешите конфликты проектов.');
    }
    await mutate((d) {
      for (final t in d.visible('task')) {
        if (ids.contains(t['projectId']) && !d.conflicted('task', t['id'])) {
          d.write('task', t, device, deleted: true);
        }
      }
      for (final p in ids) {
        d.write('project', tree.byId[p]!, device, deleted: true);
      }
    });
  });

  /// Deletes a knowledge base entry together with nested entries.
  Future<bool> deleteNotes(String id) => run(() async {
    final tree = ProjectTree(data.visible('note'), nameKey: 'title');
    final ids = tree.subtree(id);
    if (ids.any((n) => data.conflicted('note', n))) {
      throw StateError('Сначала разрешите конфликты записей.');
    }
    await mutate((d) {
      for (final n in ids) {
        d.write('note', tree.byId[n]!, device, deleted: true);
      }
    });
  });

  /// Records the start of work on a task.
  Future<bool> start(Json task) => run(() async {
    if (data.conflicted('task', task['id'])) {
      throw StateError('Сначала разрешите конфликт задачи.');
    }
    await mutate(
      (d) => d.write('task', {
        ...task,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      }, device),
    );
  });

  Future<bool> complete(Json task) => run(() async {
    if (data.conflicted('task', task['id'])) {
      throw StateError('Сначала разрешите конфликт задачи.');
    }
    await mutate((d) => d.complete(task, device));
  });

  Future<bool> resolve(String key, Json version) => run(() async {
    await mutate(
      (d) => d.write(
        version['kind'],
        clone(version['data']),
        device,
        deleted: version['deleted'],
      ),
    );
    message = 'Выбранная версия сохранена и будет отправлена в облако.';
  });

  GoogleAuth get google => GoogleAuth(
    desktopClient: prefs.getString('google_desktop_client') ?? '',
    androidServerClient: prefs.getString('google_android_server_client') ?? '',
  );

  Future<CloudStore> openStore({bool interactive = true}) async {
    if (provider == 'mail') {
      final email = await vault.read(key: 'mail_email');
      final password = await vault.read(key: 'mail_password');
      if (email == null ||
          password == null ||
          email.isEmpty ||
          password.isEmpty) {
        throw CloudFailure('Укажите почту Mail и пароль внешнего приложения.');
      }
      return MailStore(email, password);
    }
    if (provider == 'google') {
      return DriveStore(await google.token(interactive: interactive));
    }
    throw CloudFailure('Выберите облако в настройках.');
  }

  /// Full synchronization. Does not block editing: the network part runs
  /// outside the write lock, only the merge itself is serialized.
  ///
  /// Every device uploads one immutable snapshot that already contains all
  /// snapshots it has read, then deletes exactly those read snapshots. A
  /// snapshot uploaded by another device in the meantime is never deleted,
  /// so no edits are lost and the cloud folder does not grow indefinitely.
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  /// Starts synchronization. If one is already running, another pass is
  /// queued right after it, so that the latest edits are never skipped.
  Future<void> sync({bool silent = false}) async {
    if (!ready || (!cloudOn && !intakeEnabled)) return;
    if (_running != null) {
      _again = true;
      if (!silent) _loud = true;
      return _running;
    }
    _running = () async {
      var quiet = silent;
      do {
        _again = false;
        await _syncOnce(silent: quiet && !_loud);
        _loud = false;
        quiet = true;
      } while (_again && !_disposed);
    }();
    try {
      await _running;
    } finally {
      _running = null;
    }
  }

  bool _loud = false;

  Future<void> _syncOnce({required bool silent}) async {
    if (intakeEnabled) await checkMail(silent: silent);
    if (!cloudOn) return;
    syncing = true;
    syncError = null;
    syncProgress = 'Обмен с облаком…';
    notifyListeners();
    CloudStore? store;
    try {
      store = await openStore(interactive: !silent);
      final ids = await store.list();
      var remote = Dataset();
      for (final id in ids) {
        remote = remote.merge(await store.read(id));
      }
      final remoteEncoded = remote.encode();
      await locked(() async {
        final merged = data.merge(remote);
        if (merged.encode() != data.encode()) {
          await persist(merged, fromSync: true);
        }
      });
      final snapshot = data.copy();
      final blobError = await _uploadAttachments(store, snapshot);
      if (!(ids.length == 1 && remoteEncoded == snapshot.encode())) {
        await store.upload(snapshot);
        for (final id in ids) {
          await store.delete(id);
        }
      }
      if (blobError != null) throw CloudFailure(blobError);
      final now = DateTime.now().toLocal().toString().split('.').first;
      await prefs.setString('last_sync_$provider', now);
      if (!silent || data.conflicts.isNotEmpty) {
        message = data.conflicts.isEmpty
            ? 'Синхронизация завершена: $now'
            : 'Синхронизация завершена. Конфликтов: ${data.conflicts.length}. Выберите версии.';
      }
    } catch (e, stack) {
      debugPrint('Ошибка синхронизации: $e');
      debugPrintStack(stackTrace: stack);
      syncError = '$e';
      if (!silent) message = 'Синхронизация не выполнена: $e';
    } finally {
      store?.close();
      syncing = false;
      syncProgress = null;
      notifyListeners();
    }
  }

  String get _uploadedKey => 'uploaded_blobs_$provider';
  Set<String> get uploadedBlobs =>
      (prefs.getStringList(_uploadedKey) ?? const []).toSet();

  /// Forgets which files were sent, so the next sync checks every file in the
  /// cloud and uploads the missing ones again.
  // ---------- Shopping ----------

  /// Saves a purchase list: remembers new purchase names; if another list
  /// for the same date and shop exists, the items are merged into it.
  Future<bool> savePurchaseList(Json list) => run(() async {
    await mutate((d) {
      rememberProducts(d, [
        for (final i in list['items'] as List) i['text'] as String,
      ], device);
      final other = listFor(
        d,
        list['date'],
        list['shopId'],
        exceptId: list['id'],
      );
      if (other != null) {
        d.write(
          'purchase_list',
          mergeItems(other, (list['items'] as List).cast<Json>()),
          device,
        );
        if (d.records.containsKey('purchase_list:${list['id']}')) {
          d.write('purchase_list', list, device, deleted: true);
        }
      } else {
        d.write('purchase_list', list, device);
      }
    });
  });

  /// Adds chosen items of a list received by e-mail to the list for the
  /// date and shop, then removes the received list.
  Future<bool> acceptShoppingMail(
    Json inbox, {
    required String date,
    required String shopId,
    required List<Json> items,
  }) => run(() async {
    if (items.isEmpty) throw StateError('Не выбрано ни одной покупки');
    await mutate((d) {
      rememberProducts(d, items.map((i) => i['text'] as String), device);
      final existing = listFor(d, date, shopId);
      d.write(
        'purchase_list',
        existing != null
            ? mergeItems(existing, items)
            : {'id': uuid.v4(), 'date': date, 'shopId': shopId, 'items': items},
        device,
      );
      d.write('purchase_list', inbox, device, deleted: true);
    });
  });

  /// Returns the ID of the shop with this name, creating it if needed.
  Future<String?> addShop(String name) async {
    String? id;
    final ok = await run(() async {
      if (normalizeText(name).isEmpty) {
        throw StateError('Введите название магазина');
      }
      await mutate((d) => id = ensureShop(d, name, device));
    });
    return ok ? id : null;
  }

  // ---------- Planning ----------

  WorkSchedule get workSchedule => WorkSchedule.fromPrefs(prefs);

  Plan plan({DateTime? now}) => buildPlan(
    plannable(data).where((t) => !data.conflicted('task', t['id'])).toList(),
    workSchedule,
    now ?? DateTime.now(),
  );

  /// Moves due dates of the given tasks to the suggested ones.
  Future<bool> applySuggestions(List<Suggestion> list) => run(() async {
    await mutate((d) {
      for (final s in list) {
        final current = d
            .visible('task')
            .where((t) => t['id'] == s.task['id'])
            .firstOrNull;
        if (current == null || d.conflicted('task', current['id'])) continue;
        d.write(
          'task',
          moveDue(
            current,
            s.newDue,
            reason: 'Планирование: не хватает рабочего времени',
          ),
          device,
        );
      }
    });
  });

  // ---------- Export ----------

  MailSender mailSender = sendBySmtp;

  /// SMTP settings: own ones if set, otherwise those of the mailbox used for
  /// "tasks from e-mail" (imap.X → smtp.X).
  Future<SmtpSettings> smtpSettings() async {
    final intakeHost = prefs.getString('intake_host') ?? 'imap.mail.ru';
    final host = (prefs.getString('smtp_host') ?? '').trim().isNotEmpty
        ? prefs.getString('smtp_host')!.trim()
        : intakeHost.replaceFirst(RegExp(r'^imap\.'), 'smtp.');
    final user = (prefs.getString('smtp_user') ?? '').trim().isNotEmpty
        ? prefs.getString('smtp_user')!.trim()
        : (prefs.getString('intake_user') ?? '').trim();
    final password =
        await vault.read(key: 'smtp_password') ??
        await vault.read(key: 'intake_password') ??
        '';
    if (user.isEmpty || password.isEmpty) {
      throw StateError(
        'Не настроен ящик для отправки. Укажите его в окне экспорта '
        '(«Настройки отправки») или в «Задачи из почты».',
      );
    }
    return SmtpSettings(host, prefs.getInt('smtp_port') ?? 465, user, password);
  }

  String exportFileName([DateTime? now]) {
    final d = now ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Задачи_${d.year}-${two(d.month)}-${two(d.day)}_${two(d.hour)}${two(d.minute)}.xlsx';
  }

  Uint8List exportXlsx({
    Set<String>? projects,
    required Set<String> statuses,
  }) => buildXlsx(
    exportHeaders,
    exportRows(data, projects: projects, statuses: statuses),
  );

  Future<bool> sendExport({
    required String to,
    Set<String>? projects,
    required Set<String> statuses,
  }) => run(() async {
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(to.trim())) {
      throw StateError('Некорректный адрес получателя');
    }
    final rows = exportRows(data, projects: projects, statuses: statuses);
    if (rows.isEmpty) throw StateError('Нет задач с выбранными условиями');
    final settings = await smtpSettings();
    final name = exportFileName();
    final mail = buildExportMessage(
      from: settings.user,
      to: to.trim(),
      subject: 'Задачи: выгрузка ${name.substring(7, 17)}',
      text:
          'Выгрузка задач из программы «Мои проекты» $appVersion.\n'
          'Задач: ${rows.length}. Статусы: '
          '${statuses.map((s) => exportStatuses[s]).join(', ')}.',
      fileName: name,
      file: buildXlsx(exportHeaders, rows),
    );
    await mailSender(settings, mail);
    await prefs.setString('export_to', to.trim());
    message = 'Файл $name отправлен на ${to.trim()} (задач: ${rows.length}).';
  });

  // ---------- Updates ----------

  /// Reads update.json from the cloud. Null if nothing has been published.
  Future<UpdateManifest?> checkUpdate() async {
    if (!cloudOn) {
      throw StateError(
        'Обновления берутся из облака. Сначала подключите облако в настройках.',
      );
    }
    final store = await openStore(interactive: true);
    try {
      final text = await store.readText('update.json');
      return text == null ? null : UpdateManifest.parse(text);
    } finally {
      store.close();
    }
  }

  /// Downloads the installer for this platform and checks its SHA-256.
  Future<File> downloadUpdate(UpdateManifest m) async {
    final meta = m.files[platformKey];
    if (meta == null) {
      throw StateError('В облаке нет установщика для этой платформы.');
    }
    final dir = Directory('${files.directory.path}/updates');
    await dir.create(recursive: true);
    final safe = (meta['name'] as String).replaceAll(RegExp(r'[^\w.\-]'), '_');
    final target = File('${dir.path}/$safe');
    final store = await openStore(interactive: true);
    try {
      await store.getBlob(meta['sha256'], target);
    } finally {
      store.close();
    }
    if (await target.length() != meta['size'] ||
        await sha256OfFile(target) != meta['sha256']) {
      await target.delete();
      throw StateError('Файл обновления повреждён при загрузке. Повторите.');
    }
    return target;
  }

  /// Uploads installers (any of them) and writes update.json. Files for the
  /// other platform that were published earlier are kept.
  Future<UpdateManifest> publishUpdate({
    File? msix,
    File? apk,
    required String version,
    String notes = '',
  }) async {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw StateError('Версия должна быть вида 1.0.1');
    }
    if (msix == null && apk == null) {
      throw StateError('Выберите файл .msix или .apk');
    }
    final store = await openStore(interactive: true);
    try {
      final old = await store.readText('update.json');
      final files = <String, Map<String, dynamic>>{
        if (old != null && UpdateManifest.parse(old).version == version)
          ...UpdateManifest.parse(old).files,
      };
      for (final (key, file) in [('windows', msix), ('android', apk)]) {
        if (file == null) continue;
        final sha = await sha256OfFile(file);
        if (!await store.hasBlob(sha)) await store.putBlob(sha, file);
        files[key] = {
          'name': file.uri.pathSegments.last,
          'size': await file.length(),
          'sha256': sha,
        };
      }
      final m = UpdateManifest(
        version,
        notes,
        DateTime.now().toUtc().toIso8601String(),
        files,
      );
      await store.writeText('update.json', m.encode());
      return m;
    } finally {
      store.close();
    }
  }

  Future<void> resendAttachments() async {
    await prefs.remove(_uploadedKey);
    notifyListeners();
    await sync();
  }

  /// Uploads files before the snapshot, so that another device rarely sees a
  /// reference to a file that is not in the cloud yet. One failed file does
  /// not stop the others. Returns an error description or null.
  Future<String?> _uploadAttachments(CloudStore store, Dataset snapshot) async {
    final uploaded = uploadedBlobs;
    final pending = AttachmentStore.referenced(
      snapshot,
    ).where((a) => !uploaded.contains(a['sha256'])).toList();
    final errors = <String>[];
    var n = 0;
    for (final a in pending) {
      n++;
      if (!await files.available(a)) continue; // Not on this device.
      syncProgress = 'Отправка вложений: $n из ${pending.length}';
      notifyListeners();
      try {
        if (!await store.hasBlob(a['sha256'])) {
          await store.putBlob(a['sha256'], files.file(a));
        }
        uploaded.add(a['sha256']);
        await prefs.setStringList(_uploadedKey, uploaded.toList());
      } catch (e) {
        debugPrint('Вложение ${a['name']} не отправлено: $e');
        errors.add('${a['name']}: $e');
      }
    }
    if (errors.isEmpty) return null;
    return 'Не отправлено вложений: ${errors.length}. ${errors.first}';
  }

  Future<MailSettings> mailSettings() async {
    final password = await vault.read(key: 'intake_password') ?? '';
    final user = (prefs.getString('intake_user') ?? '').trim();
    final senders = (prefs.getString('intake_senders') ?? '')
        .split(RegExp(r'[\s,;]+'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.contains('@'))
        .toList();
    if (user.isEmpty || password.isEmpty) {
      throw StateError(
        'Укажите почтовый ящик и пароль для внешнего приложения.',
      );
    }
    if (senders.isEmpty) {
      throw StateError(
        'Укажите хотя бы одного разрешённого отправителя — ваш адрес, '
        'с которого вы пересылаете письма.',
      );
    }
    return MailSettings(
      host: (prefs.getString('intake_host') ?? 'imap.mail.ru').trim(),
      port: prefs.getInt('intake_port') ?? 993,
      user: user,
      password: password,
      folder: (prefs.getString('intake_folder') ?? 'INBOX').trim(),
      allowedSenders: senders,
    );
  }

  /// Reads the intake mailbox and creates inbox tasks. Letters from senders
  /// that are not allowed are left untouched in the mailbox.
  /// Returns the number of new tasks.
  Future<int>? _mailRun;
  Future<int> checkMail({bool silent = true}) {
    if (!ready) return Future.value(0);
    // A check already in progress: wait for it instead of skipping.
    return _mailRun ??= _checkMail(
      silent: silent,
    ).whenComplete(() => _mailRun = null);
  }

  Future<int> _checkMail({required bool silent}) async {
    checkingMail = true;
    mailError = null;
    notifyListeners();
    MailSource? source;
    var created = 0;
    var skipped = 0;
    var shopping = 0;
    try {
      final settings = await mailSettings();
      source = mailSource(settings);
      final letters = await source.fetch();
      final temp = Directory('${files.directory.path}/mail_tmp');
      for (final mail in letters) {
        if (!settings.allowedSenders.contains(senderOf(mail.message))) {
          skipped++;
          continue;
        }
        if (isShoppingMail(mail.message)) {
          final list = shoppingFromMail(mail);
          if (!data.records.containsKey('purchase_list:${list['id']}')) {
            await mutate((d) => d.write('purchase_list', list, device));
            shopping++;
          }
          await source.markProcessed(mail.uid);
          continue;
        }
        final id = mailTaskId(mail.message, mail.uid);
        if (!data.records.containsKey('task:$id')) {
          final task = await taskFromMail(mail, files, temp);
          await mutate((d) => d.write('task', task, device));
          created++;
        }
        // Only after the task is saved locally.
        await source.markProcessed(mail.uid);
      }
      if (shopping > 0) {
        message =
            'Из почты получено списков покупок: $shopping. Откройте вкладку «Покупки», '
            'чтобы выбрать дату и магазин.';
      }
      if (created > 0) {
        mailReceived += created;
        message =
            'Из почты получено задач: $created. Разберите их: выберите проект и сроки.'
            '${shopping > 0 ? ' Списков покупок: $shopping — во вкладке «Покупки».' : ''}';
      } else if (!silent && shopping == 0) {
        message = skipped > 0
            ? 'Новых задач нет. Писем от неразрешённых отправителей: $skipped (оставлены в ящике).'
            : 'Новых писем нет.';
      }
    } catch (e, stack) {
      debugPrint('Ошибка приёма почты: $e');
      debugPrintStack(stackTrace: stack);
      mailError = '$e';
      if (!silent) message = 'Почта не проверена: $e';
    } finally {
      await source?.close();
      checkingMail = false;
      notifyListeners();
    }
    return created;
  }

  /// Downloads an attachment that was added on another device.
  Future<File> fetchAttachment(Json a) async {
    if (await files.available(a)) return files.file(a);
    if (provider == 'none') {
      throw StateError(
        'Файл добавлен на другом устройстве. Подключите облако.',
      );
    }
    downloading.add(a['sha256']);
    notifyListeners();
    final store = await openStore();
    final tmp = files.temp();
    try {
      await files.directory.create(recursive: true);
      try {
        await store.getBlob(a['sha256'], tmp);
      } on CloudFailure catch (e) {
        if (!e.message.contains('ещё нет')) rethrow;
        throw StateError(
          'Файла ещё нет в облаке: его не отправило устройство, где он создан. '
          'Откройте программу на том устройстве и нажмите кнопку облака. '
          'Если значок облака там красный — пришлите текст ошибки.',
        );
      }
      await files.accept(tmp, a);
      return files.file(a);
    } finally {
      store.close();
      if (await tmp.exists()) await tmp.delete();
      downloading.remove(a['sha256']);
      notifyListeners();
    }
  }
}
