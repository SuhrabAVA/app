/// Очередь повторов для действий этапа, которые не долетели до сервера.
///
/// Зачем файл существует
/// --------------------
/// Действия цеха уходят одним вызовом `task_apply_stage_events` и применяются
/// целиком либо никак. Но «никак» тоже бывает: цеховой Wi-Fi роняет запрос на
/// 25-секундном таймауте, и оператор видит «нет связи». Дальше начиналось
/// самое дорогое — записи просто исчезали. Пересмена Ахтама, брони материалов,
/// закрытые интервалы: человек нажал, увидел ошибку, пошёл работать, а в базе
/// ничего нет.
///
/// Повторять автоматически было НЕЛЬЗЯ: сервер не различал «тот же запрос
/// второй раз» и «новое такое же действие». Повтор задваивал комментарий и
/// открывал второй интервал. Миграция `20260909_stage_events_idempotency.sql`
/// это сняла: у каждого намерения есть `p_request_id`, и повтор с тем же
/// ключом возвращает результат первой попытки, ничего не меняя.
///
/// Здесь — клиентская половина: намерение, которому не ответили, остаётся в
/// очереди на диске и переотправляется с тем же ключом, пока не получит ответ.
///
/// Правила, которые здесь важны
/// ---------------------------
/// * **Ключ на намерение, а не на попытку.** [StageEventRequest.requestId]
///   создаётся один раз и не меняется между попытками — иначе идемпотентность
///   не работает.
/// * **Порядок внутри задачи.** За один проход отправляется только ПЕРВОЕ
///   ожидающее намерение каждой задачи. «Закрыть интервал» не может обогнать
///   «начать этап»: применённые в обратном порядке, они дадут не то состояние.
/// * **Отказ сервера не повторяется.** «Сотрудник больше не назначен на этап»
///   от повтора не изменится — такое намерение выбрасывается и показывается
///   человеку. Повторяются только обрывы связи.
/// * **Срок жизни ограничен сроком жизни ключей на сервере.**
///   `prune_task_event_requests` держит ключи 7 дней. После этого повтор снова
///   стал бы опасен — задваивал бы запись, — поэтому просроченное намерение
///   выбрасывается с объяснением, а не отправляется втихую.
///
/// Файл намеренно не знает ни про Supabase, ни про Flutter: отправка и
/// хранилище приходят снаружи. Поэтому очередь целиком проверяется тестами без
/// сети и без плагинов.
library;

import 'dart:async';
import 'dart:convert';

/// Итог одной попытки отправки.
enum StageSendOutcome {
  /// Сервер применил намерение (или вернул результат прежней попытки).
  applied,

  /// Связь оборвалась — надо повторить с тем же ключом.
  retry,

  /// Сервер отказал по существу. Повтор ничего не изменит.
  rejected,
}

/// Ответ отправщика.
class StageSendResult {
  const StageSendResult.applied(this.payload)
      : outcome = StageSendOutcome.applied,
        error = null;

  const StageSendResult.retry(this.error)
      : outcome = StageSendOutcome.retry,
        payload = null;

  const StageSendResult.rejected(this.error)
      : outcome = StageSendOutcome.rejected,
        payload = null;

  final StageSendOutcome outcome;

  /// Ответ RPC: посчитанные сервером `assignees` и `comments`.
  final Object? payload;

  /// Человеческое описание сбоя.
  final String? error;
}

/// Намерение, ждущее подтверждения сервера.
class StageEventRequest {
  const StageEventRequest({
    required this.requestId,
    required this.taskId,
    required this.ops,
    required this.createdAtMillis,
    this.expectAssignee,
    this.attempts = 0,
    this.nextAttemptAtMillis = 0,
    this.label,
  });

  /// Ключ идемпотентности. Один на намерение, неизменен между попытками.
  final String requestId;
  final String taskId;
  final List<Map<String, dynamic>> ops;
  final String? expectAssignee;
  final int createdAtMillis;
  final int attempts;

  /// Раньше этого времени повторять бессмысленно (выдержка после сбоя).
  final int nextAttemptAtMillis;

  /// Название действия для человека: «Пересмена», «Начало этапа».
  final String? label;

  StageEventRequest copyWith({
    int? attempts,
    int? nextAttemptAtMillis,
  }) =>
      StageEventRequest(
        requestId: requestId,
        taskId: taskId,
        ops: ops,
        expectAssignee: expectAssignee,
        createdAtMillis: createdAtMillis,
        attempts: attempts ?? this.attempts,
        nextAttemptAtMillis: nextAttemptAtMillis ?? this.nextAttemptAtMillis,
        label: label,
      );

  /// Отпечаток НАМЕРЕНИЯ, без ключа и без счётчиков.
  ///
  /// Нужен, чтобы повторное нажатие той же кнопки, пока прежняя попытка ещё в
  /// очереди, переиспользовало прежний ключ. Иначе оператор, нажавший «Начать»
  /// дважды на плохой связи, создал бы два разных намерения — и оба долетели
  /// бы, задвоив интервал.
  String get fingerprint => jsonEncode({
        't': taskId,
        'o': ops,
        'e': expectAssignee,
      });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'taskId': taskId,
        'ops': ops,
        if (expectAssignee != null) 'expectAssignee': expectAssignee,
        'createdAt': createdAtMillis,
        'attempts': attempts,
        'nextAttemptAt': nextAttemptAtMillis,
        if (label != null) 'label': label,
      };

  /// Возвращает null, если строка не разбирается: битую запись лучше выкинуть,
  /// чем ронять весь разбор очереди и потерять остальные намерения.
  static StageEventRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final requestId = raw['requestId']?.toString().trim() ?? '';
    final taskId = raw['taskId']?.toString().trim() ?? '';
    if (requestId.isEmpty || taskId.isEmpty) return null;
    final rawOps = raw['ops'];
    if (rawOps is! List || rawOps.isEmpty) return null;
    final ops = <Map<String, dynamic>>[];
    for (final op in rawOps) {
      if (op is Map) ops.add(Map<String, dynamic>.from(op));
    }
    if (ops.isEmpty) return null;
    final expect = raw['expectAssignee']?.toString().trim();
    return StageEventRequest(
      requestId: requestId,
      taskId: taskId,
      ops: ops,
      expectAssignee: (expect == null || expect.isEmpty) ? null : expect,
      createdAtMillis: _asInt(raw['createdAt']),
      attempts: _asInt(raw['attempts']),
      nextAttemptAtMillis: _asInt(raw['nextAttemptAt']),
      label: raw['label']?.toString(),
    );
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

/// Хранилище очереди. Одна строка — весь список.
///
/// Реализация на диске живёт в приложении; тесты подставляют свою.
abstract class StageOutboxStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Хранилище в памяти: для тестов и как заглушка, если диск недоступен.
class MemoryStageOutboxStore implements StageOutboxStore {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async {
    _value = value;
  }
}

typedef StageOutboxSender = Future<StageSendResult> Function(
    StageEventRequest request);

/// Выдержка перед следующей попыткой.
///
/// Первые повторы частые — обрыв на цеховой сети обычно длится секунды.
/// Дальше реже, чтобы планшет не долбил мёртвый роутер весь день.
const List<int> kStageRetryBackoffMillis = <int>[
  2000,
  5000,
  10000,
  30000,
  60000,
  120000,
  300000,
];

/// Дольше этого намерение не хранится: сервер забывает ключ через 7 дней
/// (`prune_task_event_requests`), и повтор после этого снова начал бы двоить.
const Duration kStageRequestMaxAge = Duration(days: 7);

/// Очередь намерений, не получивших ответа.
class StageEventOutbox {
  StageEventOutbox({
    required StageOutboxSender sender,
    StageOutboxStore? store,
    this.onApplied,
    this.onRejected,
    this.onChanged,
    Duration maxAge = kStageRequestMaxAge,
  })  : _sender = sender,
        _store = store ?? MemoryStageOutboxStore(),
        _maxAgeMillis = maxAge.inMilliseconds;

  final StageOutboxSender _sender;
  final StageOutboxStore _store;
  final int _maxAgeMillis;

  /// Сервер применил намерение: экрану надо показать посчитанное им состояние.
  final void Function(StageEventRequest request, Object? payload)? onApplied;

  /// Намерение выброшено: повтор бессмыслен. Человек должен об этом узнать.
  final void Function(StageEventRequest request, String reason)? onRejected;

  /// Размер очереди изменился — обновить индикатор.
  final void Function()? onChanged;

  final List<StageEventRequest> _pending = <StageEventRequest>[];
  bool _loaded = false;
  bool _flushing = false;

  int get pendingCount => _pending.length;

  List<StageEventRequest> get pending => List.unmodifiable(_pending);

  /// Читает очередь с диска. Вызывать один раз при старте.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    String? raw;
    try {
      raw = await _store.read();
    } catch (_) {
      // Недоступное хранилище не должно мешать работе: очередь просто начнётся
      // пустой, а новые намерения будут жить в памяти до конца сессии.
      return;
    }
    if (raw == null || raw.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    final list = decoded is Map ? decoded['requests'] : decoded;
    if (list is! List) return;
    for (final item in list) {
      final request = StageEventRequest.fromJson(item);
      if (request != null) _pending.add(request);
    }
    if (_pending.isNotEmpty) onChanged?.call();
  }

  /// Ключ уже стоящего в очереди такого же намерения, если он есть.
  ///
  /// Повторное нажатие кнопки на плохой связи должно переиспользовать ключ, а
  /// не создавать второе намерение.
  String? pendingIdFor(StageEventRequest candidate) {
    final print = candidate.fingerprint;
    for (final request in _pending) {
      if (request.fingerprint == print) return request.requestId;
    }
    return null;
  }

  /// Ставит намерение в очередь. Повторный вызов с тем же ключом ничего не
  /// добавляет — это тот же самый запрос, просто ещё раз не долетевший.
  Future<void> enqueue(
    StageEventRequest request, {
    required int nowMillis,
  }) async {
    if (_pending.any((r) => r.requestId == request.requestId)) return;
    final attempts = request.attempts == 0 ? 1 : request.attempts;
    _pending.add(request.copyWith(
      attempts: attempts,
      nextAttemptAtMillis: nowMillis + backoffMillis(attempts),
    ));
    await _persist();
    onChanged?.call();
  }

  /// Выдержка после [attempts] неудачных попыток.
  static int backoffMillis(int attempts) {
    if (attempts <= 1) return kStageRetryBackoffMillis.first;
    final index = attempts - 1;
    return index >= kStageRetryBackoffMillis.length
        ? kStageRetryBackoffMillis.last
        : kStageRetryBackoffMillis[index];
  }

  /// Отправляет всё, чему пришёл срок. Возвращает число применённых намерений.
  ///
  /// За проход по каждой задаче идёт только первое ожидающее намерение: пока
  /// оно не применилось, следующие ждут. Как только оно уходит, его место
  /// занимает следующее — и тоже отправляется в этом же проходе.
  Future<int> flush({required int nowMillis}) async {
    if (_flushing) return 0;
    _flushing = true;
    var applied = 0;
    var changed = false;
    try {
      // Задачи, чья голова очереди на этом проходе не прошла: остальные их
      // намерения трогать нельзя — порядок важнее скорости.
      final blocked = <String>{};
      while (true) {
        _dropExpired(nowMillis, () => changed = true);
        final request = _nextDue(nowMillis, blocked);
        if (request == null) break;

        StageSendResult result;
        try {
          result = await _sender(request);
        } catch (e) {
          // Отправщик не обязан быть аккуратным: любое исключение считаем
          // обрывом и повторяем. Потерять намерение хуже, чем послать лишний
          // раз — ключ защищает от задвоения.
          result = StageSendResult.retry(e.toString());
        }

        switch (result.outcome) {
          case StageSendOutcome.applied:
            _remove(request.requestId);
            changed = true;
            applied += 1;
            onApplied?.call(request, result.payload);
            break;
          case StageSendOutcome.rejected:
            _remove(request.requestId);
            changed = true;
            onRejected?.call(
              request,
              result.error ?? 'Сервер отклонил действие.',
            );
            break;
          case StageSendOutcome.retry:
            final attempts = request.attempts + 1;
            _replace(request.copyWith(
              attempts: attempts,
              nextAttemptAtMillis: nowMillis + backoffMillis(attempts),
            ));
            changed = true;
            blocked.add(request.taskId);
            break;
        }
      }
    } finally {
      _flushing = false;
      if (changed) {
        await _persist();
        onChanged?.call();
      }
    }
    return applied;
  }

  /// Ближайшее время, когда стоит проснуться. null — если очередь пуста.
  int? get nextAttemptAtMillis {
    int? soonest;
    for (final request in _pending) {
      final at = request.nextAttemptAtMillis;
      if (soonest == null || at < soonest) soonest = at;
    }
    return soonest;
  }

  StageEventRequest? _nextDue(int nowMillis, Set<String> blocked) {
    final seen = <String>{};
    for (final request in _pending) {
      // Первое встреченное намерение задачи — её голова очереди.
      if (!seen.add(request.taskId)) continue;
      if (blocked.contains(request.taskId)) continue;
      if (request.nextAttemptAtMillis <= nowMillis) return request;
    }
    return null;
  }

  void _dropExpired(int nowMillis, void Function() markChanged) {
    if (_pending.isEmpty) return;
    final expired = _pending
        .where((r) =>
            r.createdAtMillis > 0 &&
            nowMillis - r.createdAtMillis > _maxAgeMillis)
        .toList();
    for (final request in expired) {
      _remove(request.requestId);
      markChanged();
      onRejected?.call(
        request,
        'Действие так и не удалось отправить — оно ждало связи дольше недели '
        'и было отменено. Проверьте задание и при необходимости повторите.',
      );
    }
  }

  void _remove(String requestId) {
    _pending.removeWhere((r) => r.requestId == requestId);
  }

  void _replace(StageEventRequest request) {
    final index =
        _pending.indexWhere((r) => r.requestId == request.requestId);
    if (index == -1) return;
    _pending[index] = request;
  }

  Future<void> _persist() async {
    try {
      await _store.write(jsonEncode({
        'version': 1,
        'requests': [for (final r in _pending) r.toJson()],
      }));
    } catch (_) {
      // Диск может быть недоступен (нет прав, кончилось место). Очередь
      // остаётся в памяти и доработает в этой сессии.
    }
  }
}
