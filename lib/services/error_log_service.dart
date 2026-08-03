import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Показывать ли плавающую кнопку ошибок поверх приложения.
/// Перед релизом достаточно поставить false — перехват ошибок и запись
/// в файл при этом продолжают работать.
const bool kShowErrorOverlay = true;

/// Одна запись об ошибке за сессию.
class AppErrorEntry {
  AppErrorEntry({
    required this.time,
    required this.source,
    required this.message,
    this.stack,
    this.context,
  });

  final DateTime time;

  /// Откуда пришла ошибка: FLUTTER / PLATFORM / ZONE / LOG / SUPABASE (...).
  final String source;
  final String message;
  final String? stack;

  /// Экран/контекст, если известен (например, из FlutterErrorDetails.context).
  final String? context;

  String format() {
    final buf = StringBuffer('[${time.toIso8601String()}] [$source] ');
    final ctx = context;
    if (ctx != null && ctx.isNotEmpty) {
      buf.write('($ctx) ');
    }
    buf.write(message);
    final st = stack;
    if (st != null && st.trim().isNotEmpty) {
      buf.write('\n${st.trimRight()}');
    }
    return buf.toString();
  }
}

/// Глобальный журнал ошибок: держит список за сессию (для оверлея)
/// и пишет всё в файл errors_log.txt с ротацией.
///
/// Сам никогда не бросает исключений и не вызывает debugPrint,
/// чтобы не зациклиться и не сломать приложение.
class ErrorLogService {
  ErrorLogService._();

  static final ErrorLogService instance = ErrorLogService._();

  static const int _maxEntries = 500;
  static const int _maxLogBytes = 2 * 1024 * 1024; // ~2 МБ
  static const int _pendingLimit = 200;

  /// Ошибки текущей сессии (новые — в конце).
  final List<AppErrorEntry> entries = <AppErrorEntry>[];

  /// Инкрементируется при любом изменении списка — для перестроения UI.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Количество ошибок, которые пользователь ещё не просматривал.
  final ValueNotifier<int> unseenCount = ValueNotifier<int>(0);

  /// Полный путь к лог-файлу (после init).
  String? logFilePath;

  File? _file;
  final List<String> _pendingLines = <String>[];
  Future<void> _writeChain = Future<void>.value();
  int _writesSinceCheck = 0;
  bool _muted = false;

  /// Инициализация файла лога. Вызывать после ensureInitialized;
  /// до готовности файла записи буферизуются в памяти.
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}errors_log.txt');
      await file.parent.create(recursive: true);
      _file = file;
      logFilePath = file.path;
      await _rotateIfNeeded();
      if (_pendingLines.isNotEmpty) {
        final lines = List<String>.from(_pendingLines);
        _pendingLines.clear();
        for (final line in lines) {
          _enqueueWrite(line);
        }
      }
    } catch (_) {
      // Логгер не должен ломать запуск приложения.
    }
  }

  /// Зафиксировать ошибку: в список сессии + в файл.
  void record({
    required String source,
    required String message,
    String? stack,
    String? context,
  }) {
    try {
      final entry = AppErrorEntry(
        time: DateTime.now(),
        source: _refineSource(source, message),
        message: message,
        stack: stack,
        context: context,
      );
      entries.add(entry);
      if (entries.length > _maxEntries) {
        entries.removeRange(0, entries.length - _maxEntries);
      }
      unseenCount.value = unseenCount.value + 1;
      revision.value = revision.value + 1;

      final line = entry.format();
      if (_file == null) {
        _pendingLines.add(line);
        if (_pendingLines.length > _pendingLimit) {
          _pendingLines.removeAt(0);
        }
      } else {
        _enqueueWrite(line);
      }
    } catch (_) {
      // Никогда не роняем приложение из логгера.
    }
  }

  /// Перехват всех debugPrint: строки, похожие на ошибки (❌/⚠️/error/
  /// failed/exception/ошибка), попадают в журнал. Остальной вывод
  /// проходит без изменений.
  void installDebugPrintHook() {
    final DebugPrintCallback previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      previous(message, wrapWidth: wrapWidth);
      if (message == null || _muted) {
        return;
      }
      try {
        _maybeRecordLogLine(message);
      } catch (_) {
        // Хук не должен влиять на вывод.
      }
    };
  }

  /// Выполнить fn, не перехватывая debugPrint (защита от дублей,
  /// когда FlutterError.presentError печатает ошибку в консоль).
  T runMuted<T>(T Function() fn) {
    _muted = true;
    try {
      return fn();
    } finally {
      _muted = false;
    }
  }

  void markAllSeen() {
    unseenCount.value = 0;
  }

  /// Очистить список сессии (файл лога не трогаем).
  void clear() {
    entries.clear();
    unseenCount.value = 0;
    revision.value = revision.value + 1;
  }

  String formatAll() {
    if (entries.isEmpty) {
      return 'Ошибок за сессию нет.';
    }
    final buf = StringBuffer('Ошибок за сессию: ${entries.length}\n\n');
    for (final e in entries) {
      buf
        ..writeln(e.format())
        ..writeln('-' * 60);
    }
    return buf.toString();
  }

  // ------------------------------------------------------ внутреннее

  static String _refineSource(String source, String message) {
    if (message.contains('PostgrestException') ||
        message.contains('StorageException') ||
        message.contains('AuthException') ||
        message.contains('RealtimeSubscribeException')) {
      return 'SUPABASE ($source)';
    }
    return source;
  }

  void _maybeRecordLogLine(String message) {
    // Пропускаем строки консольного дампа Flutter-ошибок —
    // они уже записаны через FlutterError.onError.
    if (message.contains('══') ||
        message.startsWith('Another exception was thrown')) {
      return;
    }
    final lower = message.toLowerCase();
    final looksLikeError = message.contains('❌') ||
        message.contains('⚠') ||
        lower.contains('error') ||
        lower.contains('exception') ||
        lower.contains('failed') ||
        lower.contains('ошибк');
    if (!looksLikeError) {
      return;
    }
    record(source: 'LOG', message: message);
  }

  void _enqueueWrite(String line) {
    final file = _file;
    if (file == null) {
      return;
    }
    // Пишем строго последовательно, чтобы строки не перемешивались.
    _writeChain = _writeChain.then((_) async {
      try {
        await file.writeAsString('$line\n', mode: FileMode.append);
        _writesSinceCheck++;
        if (_writesSinceCheck >= 20) {
          _writesSinceCheck = 0;
          await _rotateIfNeeded();
        }
      } catch (_) {
        // Файловая ошибка не должна ломать приложение.
      }
    });
  }

  /// Если файл превысил ~2 МБ — оставляем последнюю половину
  /// (с выравниванием по границе строки).
  Future<void> _rotateIfNeeded() async {
    final file = _file;
    if (file == null) {
      return;
    }
    try {
      if (!await file.exists()) {
        return;
      }
      final length = await file.length();
      if (length <= _maxLogBytes) {
        return;
      }
      final bytes = await file.readAsBytes();
      var start = bytes.length - _maxLogBytes ~/ 2;
      while (start < bytes.length && bytes[start] != 0x0A) {
        start++;
      }
      final tail =
          start < bytes.length ? bytes.sublist(start + 1) : <int>[];
      await file.writeAsBytes(tail, flush: true);
    } catch (_) {
      // Ротация best-effort.
    }
  }
}
