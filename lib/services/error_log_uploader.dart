import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/auth_helper.dart';
import 'error_log_service.dart';

/// Выгрузка журнала ошибок в Supabase (таблица `app_error_logs`).
///
/// Локальный лог живёт только пока открыто приложение: после выхода
/// сотрудника или выключения планшета он недоступен. Поэтому записи
/// выгружаются на сервер в моменты, когда сессия заканчивается:
///  * приложение уходит в фон или закрывается (`paused` / `detached`);
///  * сотрудник выходит из аккаунта;
///  * на старте — «хвост», не успевший уйти в прошлый раз.
///
/// Никогда не бросает исключений: сбой выгрузки не должен мешать работе,
/// а свои же ошибки логгер писать не может — иначе зациклится.
class ErrorLogUploader {
  ErrorLogUploader._();

  static final ErrorLogUploader instance = ErrorLogUploader._();

  static const String _table = 'app_error_logs';

  /// Edge Function, которая отправляет письмо со свежими логами.
  ///
  /// Имя историческое: при деплое через веб-редактор Supabase подставил
  /// `rapid-processor`, переименование потребовало бы передеплоя. Код функции
  /// лежит в `supabase/functions/send-error-log-email/index.ts`.
  ///
  /// Вызываем её сразу после вставки: планировщик (pg_cron) на проекте не
  /// срабатывает, а ждать его и не нужно — письмо должно уходить в момент,
  /// когда сотрудник закрыл приложение. Ключ почтового сервиса остаётся на
  /// сервере, в APK попадает только публичный вызов функции.
  static const String _emailFunction = 'rapid-processor';
  static const String _prefsPendingKey = 'error_log_pending_entries';
  static const String _prefsSessionKey = 'error_log_session_id';

  /// Сколько записей максимум уходит одной партией: письмо и строка в БД
  /// не должны раздуваться до мегабайтов при шторме ошибок.
  static const int _maxEntriesPerBatch = 200;

  String? _sessionId;
  DateTime? _sessionStartedAt;

  /// Индекс первой ещё не выгруженной записи в [ErrorLogService.entries].
  int _uploadedCount = 0;

  bool _busy = false;

  Future<void> init() async {
    _sessionStartedAt = DateTime.now();
    _sessionId = '${_sessionStartedAt!.microsecondsSinceEpoch}'
        '-${identityHashCode(this)}';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsSessionKey, _sessionId!);
    } catch (_) {}
    // Досылаем то, что не ушло в прошлую сессию (выключили планшет и т.п.).
    await flushPending(reason: 'startup_flush');
  }

  /// Выгружает накопленные записи. [reason] — что вызвало выгрузку:
  /// `paused`, `detached`, `logout`, `startup_flush`.
  Future<void> flush({required String reason}) async {
    if (_busy) return;
    _busy = true;
    try {
      final all = ErrorLogService.instance.entries;
      if (_uploadedCount > all.length) {
        // Журнал обрезался ротацией — начинаем с текущего конца.
        _uploadedCount = all.length;
      }
      final fresh = all.skip(_uploadedCount).toList(growable: false);
      if (fresh.isEmpty) return;

      final batch = fresh.length > _maxEntriesPerBatch
          ? fresh.sublist(fresh.length - _maxEntriesPerBatch)
          : fresh;
      final payload = batch.map(_entryToMap).toList(growable: false);

      final sent = await _send(reason: reason, entries: payload);
      if (sent) {
        _uploadedCount = all.length;
      } else {
        // Нет сети — откладываем до следующего запуска.
        await _savePending(payload, reason: reason);
        _uploadedCount = all.length;
      }
    } catch (_) {
      // Молча: логгер не имеет права ронять приложение.
    } finally {
      _busy = false;
    }
  }

  /// Отправляет отложенные записи прошлых сессий, если они есть.
  Future<void> flushPending({required String reason}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsPendingKey);
      if (raw == null || raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) {
        await prefs.remove(_prefsPendingKey);
        return;
      }
      final entries = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

      final sent = await _send(reason: reason, entries: entries);
      if (sent) {
        await prefs.remove(_prefsPendingKey);
      }
    } catch (_) {}
  }

  Future<void> _savePending(
    List<Map<String, dynamic>> entries, {
    required String reason,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsPendingKey);
      final merged = <Map<String, dynamic>>[];
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          merged.addAll(
            decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
          );
        }
      }
      merged.addAll(entries);
      final trimmed = merged.length > _maxEntriesPerBatch
          ? merged.sublist(merged.length - _maxEntriesPerBatch)
          : merged;
      await prefs.setString(_prefsPendingKey, jsonEncode(trimmed));
    } catch (_) {}
  }

  Map<String, dynamic> _entryToMap(AppErrorEntry e) => <String, dynamic>{
        // Строго UTC с суффиксом Z: значение уходит в jsonb, где часовой пояс
        // больше ниоткуда не восстановить. Без Z читающая сторона трактовала
        // локальное алматинское время как UTC и показывала его на 5 часов
        // мимо created_at той же строки.
        'time': e.time.toUtc().toIso8601String(),
        'source': e.source,
        'message': e.message,
        if (e.stack != null && e.stack!.trim().isNotEmpty) 'stack': e.stack,
        if (e.context != null && e.context!.trim().isNotEmpty)
          'context': e.context,
      };

  Future<bool> _send({
    required String reason,
    required List<Map<String, dynamic>> entries,
  }) async {
    if (entries.isEmpty) return true;
    try {
      await Supabase.instance.client.from(_table).insert({
        'employee_id': AuthHelper.currentUserId,
        'employee_name': AuthHelper.currentUserName,
        'device_model': _deviceLabel(),
        'platform': _platformLabel(),
        'session_id': _sessionId ?? 'unknown',
        // TODO(T1): наивная локальная строка в колонку timestamptz — тот же
        // класс ошибки, что и в остальных 16 местах. Не трогаем до решения
        // по миграции данных, иначе старые и новые строки будут разного
        // смысла в одной колонке.
        if (_sessionStartedAt != null)
          'session_started_at': _sessionStartedAt!.toIso8601String(),
        'reason': reason,
        'entries_count': entries.length,
        'entries': entries,
      });
      await _requestEmail();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Просит сервер отправить письмо с ещё не отправленными записями.
  ///
  /// Отдельно от вставки: если письмо не ушло (нет сети, функция недоступна),
  /// записи уже лежат в таблице и уйдут со следующим вызовом — терять их
  /// нельзя, а вот повторить отправку не проблема.
  Future<void> _requestEmail() async {
    try {
      await Supabase.instance.client.functions
          .invoke(_emailFunction)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Приложение в этот момент уже уходит в фон — ждать дольше нельзя,
      // а неудача не критична: данные сохранены.
    }
  }

  String _platformLabel() {
    if (kIsWeb) return 'web';
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  String _deviceLabel() {
    if (kIsWeb) return 'web';
    try {
      return Platform.operatingSystemVersion;
    } catch (_) {
      return 'unknown';
    }
  }
}
