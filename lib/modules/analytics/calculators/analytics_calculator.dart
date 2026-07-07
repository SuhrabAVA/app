import '../models/analytics_event.dart';

/// Расчётные функции по списку событий.
class AnalyticsCalculator {
  AnalyticsCalculator._();

  static int _minutes(AnalyticsEvent e, DateTime now) =>
      e.durationMinutesEffective(now);

  /// Полезные минуты — только тип Работа.
  static int usefulMinutes(Iterable<AnalyticsEvent> events,
      {DateTime? now}) {
    final ref = now ?? DateTime.now();
    var sum = 0;
    for (final e in events) {
      if (e.type == AnalyticsEventType.work) sum += _minutes(e, ref);
    }
    return sum;
  }

  static int setupMinutes(Iterable<AnalyticsEvent> events, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    var sum = 0;
    for (final e in events) {
      if (e.type == AnalyticsEventType.setup) sum += _minutes(e, ref);
    }
    return sum;
  }

  static int pauseMinutes(Iterable<AnalyticsEvent> events, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    var sum = 0;
    for (final e in events) {
      if (e.type == AnalyticsEventType.pause) sum += _minutes(e, ref);
    }
    return sum;
  }

  static int problemMinutes(Iterable<AnalyticsEvent> events, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    var sum = 0;
    for (final e in events) {
      if (e.type == AnalyticsEventType.problem) sum += _minutes(e, ref);
    }
    return sum;
  }

  static int countEventsOfType(
      Iterable<AnalyticsEvent> events, AnalyticsEventType type) {
    var n = 0;
    for (final e in events) {
      if (e.type == type) n++;
    }
    return n;
  }

  static double totalQty(Iterable<AnalyticsEvent> events) {
    var sum = 0.0;
    for (final e in events) {
      if (e.type == AnalyticsEventType.work) sum += e.qty;
    }
    return sum;
  }

  static double totalSetupQty(Iterable<AnalyticsEvent> events) {
    var sum = 0.0;
    for (final e in events) {
      if (e.type == AnalyticsEventType.setup) sum += e.setupQty;
    }
    return sum;
  }

  /// Суммарная длительность ВСЕХ событий (любого типа) в минутах.
  static int totalMinutes(Iterable<AnalyticsEvent> events, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    var sum = 0;
    for (final e in events) {
      sum += _minutes(e, ref);
    }
    return sum;
  }

  /// КПД сотрудника по эталону (app.js: employeeSummary.kpd):
  /// полезное (рабочее) время / общее время всех событий × 100.
  /// Это ИНАЯ метрика, чем КПД рабочего места (там — скорость месяца против
  /// средней прошлых, [KpdCalculator]); поэтому отдельный расчёт по времени.
  /// При нулевом общем времени — 0.
  static int timeKpdPercent(Iterable<AnalyticsEvent> events, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    final useful = usefulMinutes(events, now: ref);
    final total = totalMinutes(events, now: ref);
    if (total <= 0) return 0;
    return ((useful / total) * 100).round();
  }

  /// Скорость в ед./мин по работе. Если полезных минут 0 — возвращает 0.
  static double speedQtyPerMinute(Iterable<AnalyticsEvent> events,
      {DateTime? now}) {
    final qty = totalQty(events);
    final minutes = usefulMinutes(events, now: now);
    if (minutes <= 0 || !qty.isFinite) return 0;
    return qty / minutes;
  }
}
