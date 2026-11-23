import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'domain.dart';

class Reminders {
  final plugin = FlutterLocalNotificationsPlugin();
  bool initialized = false;
  bool get supported => Platform.isAndroid || Platform.isWindows;
  final SharedPreferences prefs;
  Reminders(this.prefs);
  Future<void> initialize() async {
    if (!supported || initialized) return;
    tzdata.initializeTimeZones();
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        windows: WindowsInitializationSettings(
          appName: 'Мои проекты',
          appUserModelId: 'ProjectReminders.Personal',
          guid: '76ba624c-ae22-42bd-a926-b89c0b26323e',
        ),
      ),
    );
    initialized = true;
  }

  Future<String> permissions() async {
    await initialize();
    if (Platform.isWindows) {
      return 'Windows: используйте установленную MSIX-версию. '
          'Проверьте уведомления приложения в настройках Windows и тест ниже.';
    }
    if (!Platform.isAndroid) return 'Эта платформа не поддерживается.';
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()!;
    final granted = await android.requestNotificationsPermission();
    final exact = await android.requestExactAlarmsPermission();
    return 'Уведомления: ${granted == true ? "разрешены" : "не разрешены"}. '
        'Точное время: ${exact == true ? "разрешено" : "не разрешено, возможна задержка"}.';
  }

  NotificationDetails get details => const NotificationDetails(
    android: AndroidNotificationDetails(
      'project_tasks_v2',
      'Задачи проектов',
      channelDescription: 'Напоминания о ваших задачах',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    windows: WindowsNotificationDetails(),
  );
  Future<AndroidScheduleMode> mode() async {
    if (!Platform.isAndroid) return AndroidScheduleMode.exactAllowWhileIdle;
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()!;
    return await android.canScheduleExactNotifications() == true
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  Future<void> test() async {
    if (!supported) {
      throw StateError('Тест доступен только на Windows и Android');
    }
    await initialize();
    if (Platform.isWindows && !MsixUtils.hasPackageIdentity()) {
      throw StateError('Сначала установите MSIX-версию приложения');
    }
    await plugin.zonedSchedule(
      2147483646,
      'Тест напоминания',
      'Системное уведомление «Мои проекты».',
      tz.TZDateTime.now(tz.UTC).add(const Duration(seconds: 30)),
      details,
      androidScheduleMode: await mode(),
    );
  }

  Future<String?> reconcile(Dataset data) async {
    if (!supported) return null;
    await initialize();
    if (Platform.isWindows &&
        (!MsixUtils.hasPackageIdentity() ||
            prefs.getBool('windows_msix_confirmed') != true)) {
      if (MsixUtils.hasPackageIdentity()) {
        await plugin.cancelAll();
        await prefs.remove('notification_schedule');
      }
      return 'Напоминания Windows выключены до установки MSIX. '
          'После установки включите их в настройках.';
    }
    final oldRaw = prefs.getString('notification_schedule') ?? '{}';
    final old = Map<String, dynamic>.from(jsonDecode(oldRaw));
    final wanted = <String, dynamic>{};
    final tasks = data.visible('task')
      ..sort((a, b) => a['id'].compareTo(b['id']));
    final used = <int>{2147483646};
    final scheduleMode = await mode();
    final now = DateTime.now();
    for (final t in tasks) {
      if (t['done'] == true ||
          t['reminder'] == null ||
          data.conflicted('task', t['id'])) {
        continue;
      }
      final date = DateTime.parse(t['reminder']);
      if (!date.isAfter(now)) continue;
      final digest = sha256.convert(utf8.encode(t['id'])).bytes;
      var id =
          ((digest[0] << 24) |
              (digest[1] << 16) |
              (digest[2] << 8) |
              digest[3]) &
          0x7fffffff;
      while (!used.add(id)) {
        id = (id + 1) & 0x7fffffff;
      }
      wanted['$id'] = {
        'date': date.toUtc().toIso8601String(),
        'title': t['title'],
        'task': t['id'],
        'mode': scheduleMode.name,
      };
    }
    final pending = (await plugin.pendingNotificationRequests())
        .map((n) => n.id)
        .toSet();
    for (final id in pending) {
      if (id != 2147483646 && !wanted.containsKey('$id')) {
        await plugin.cancel(id);
      }
    }
    for (final id in old.keys.toList()) {
      if (!pending.contains(int.parse(id))) old.remove(id);
    }
    // Persist progress after each operation; retries remain safe after partial failure.
    for (final id in old.keys.toList()) {
      if (canonical(old[id]) != canonical(wanted[id])) {
        await plugin.cancel(int.parse(id));
        old.remove(id);
        await prefs.setString('notification_schedule', jsonEncode(old));
      }
    }
    for (final entry in wanted.entries) {
      if (canonical(old[entry.key]) == canonical(entry.value)) continue;
      final value = entry.value;
      // Also clears an orphan left by a crash between native scheduling and
      // persisting the local schedule index.
      if (pending.contains(int.parse(entry.key))) {
        await plugin.cancel(int.parse(entry.key));
      }
      await plugin.zonedSchedule(
        int.parse(entry.key),
        'Мои проекты',
        value['title'],
        tz.TZDateTime.from(DateTime.parse(value['date']), tz.UTC),
        details,
        androidScheduleMode: scheduleMode,
        payload: value['task'],
      );
      old[entry.key] = value;
      await prefs.setString('notification_schedule', jsonEncode(old));
    }
    if (Platform.isAndroid) {
      final enabled = await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!
          .areNotificationsEnabled();
      if (enabled != true) {
        return 'Уведомления запрещены Android. Разрешите их в настройках.';
      }
      if (scheduleMode == AndroidScheduleMode.inexactAllowWhileIdle) {
        return 'Точные будильники не разрешены: напоминания могут задерживаться.';
      }
    }
    return data.conflicts.isEmpty
        ? null
        : 'Напоминания конфликтующих задач приостановлены до выбора версии.';
  }
}
