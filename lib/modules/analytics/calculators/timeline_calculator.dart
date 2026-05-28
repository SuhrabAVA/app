import '../models/analytics_event.dart';
import '../models/day_shift_type.dart';
import '../models/work_schedule_entry.dart';
import '../utils/analytics_constants.dart';

/// Сегмент timeline: [startMinutes; endMinutes] в минутах от полуночи дня.
class TimelineSegment {
  final int startMinutes;
  final int endMinutes;
  final AnalyticsEventType type;
  /// Источник: null для idle/overlap; иначе исходное событие.
  final AnalyticsEvent? event;
  /// Список источников, если сегмент — пересечение нескольких событий.
  final List<AnalyticsEvent> overlappingEvents;
  final bool isOverlap;
  /// Сегмент относится к «следующему» дню — был перенос через полночь.
  final bool crossesMidnight;

  const TimelineSegment({
    required this.startMinutes,
    required this.endMinutes,
    required this.type,
    this.event,
    this.overlappingEvents = const [],
    this.isOverlap = false,
    this.crossesMidnight = false,
  });

  int get durationMinutes => endMinutes - startMinutes;
}

class TimelineLayout {
  /// Старт шкалы — минут от полуночи (может быть 0..1440).
  final int startMinutes;
  /// Конец шкалы — минут от полуночи (может быть >1440 при переносе).
  final int endMinutes;
  final List<TimelineSegment> segments;
  final List<int> hourlyTicks;

  const TimelineLayout({
    required this.startMinutes,
    required this.endMinutes,
    required this.segments,
    required this.hourlyTicks,
  });

  int get totalMinutes => endMinutes - startMinutes;
}

class TimelineCalculator {
  TimelineCalculator._();

  /// Собирает timeline для выбранного дня сотрудника.
  ///
  /// [day]      — дата (00:00..23:59 локального дня), события привязываются к ней
  /// [events]   — события, относящиеся к этому дню
  /// [schedule] — запись графика (опционально)
  static TimelineLayout build({
    required DateTime day,
    required List<AnalyticsEvent> events,
    WorkScheduleEntry? schedule,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final midnight = DateTime(day.year, day.month, day.day);

    int toMinutesFromMidnight(DateTime dt) {
      final diff = dt.difference(midnight).inMinutes;
      return diff;
    }

    // 1. Определяем базовый старт.
    final shiftType = schedule?.shiftType ?? _guessShiftType(events, midnight);
    final defaults = WorkScheduleEntry.defaultsFor(shiftType);
    final arrival = schedule?.arrivalTime ?? defaults.$1;

    int baseStart;
    int baseEnd;
    if (shiftType == DayShiftType.night) {
      baseStart = AnalyticsConstants.nightShiftStartMinutes;
      baseEnd = baseStart + AnalyticsConstants.shiftMinutes; // 20:00 -> 08:00 next
    } else {
      baseStart = AnalyticsConstants.dayShiftStartMinutes;
      baseEnd = AnalyticsConstants.dayShiftEndMinutes;
    }
    if (arrival != null && arrival.isNotEmpty) {
      final parsed = _parseHHMM(arrival);
      if (parsed != null) {
        // Для ночной смены приход типа "20:00" уже > baseStart значит нормально.
        // Для дневной смены приход "07:00" < baseStart значит расширяем влево.
        if (shiftType != DayShiftType.night && parsed < baseStart) {
          baseStart = parsed;
        }
      }
    }

    // Если есть события, корректируем границы по фактам.
    for (final e in events) {
      final s = toMinutesFromMidnight(e.startTime);
      final endTime = e.endTime ?? reference;
      var en = toMinutesFromMidnight(endTime);
      if (en < s) en = s; // защита
      if (s < baseStart) baseStart = s;
      if (en > baseEnd) baseEnd = en;
    }

    // Защита: если совсем нет данных и баз нет — берём стандартный диапазон.
    if (baseEnd <= baseStart) {
      baseStart = AnalyticsConstants.dayShiftStartMinutes;
      baseEnd = AnalyticsConstants.dayShiftEndMinutes;
    }

    // 2. Готовим прямые интервалы событий (в минутах от полуночи).
    final intervals = <_RawInterval>[];
    for (final e in events) {
      final s = toMinutesFromMidnight(e.startTime);
      final endTime = e.endTime ?? reference;
      var en = toMinutesFromMidnight(endTime);
      if (en < s) en = s;
      if (en <= baseStart || s >= baseEnd) continue; // вне видимого окна
      final clampedStart = s < baseStart ? baseStart : s;
      final clampedEnd = en > baseEnd ? baseEnd : en;
      if (clampedEnd <= clampedStart) continue;
      intervals.add(_RawInterval(clampedStart, clampedEnd, e));
    }

    // 3. Sweep-line: для каждой временной точки определяем множество активных
    //    событий. Если несколько — это пересечение (фиолетовый).
    final breakpoints = <int>{baseStart, baseEnd};
    for (final iv in intervals) {
      breakpoints.add(iv.start);
      breakpoints.add(iv.end);
    }
    final sortedBP = breakpoints.toList()..sort();

    final segments = <TimelineSegment>[];
    for (var i = 0; i < sortedBP.length - 1; i++) {
      final a = sortedBP[i];
      final b = sortedBP[i + 1];
      if (b <= a) continue;
      // Найти все события, активные на [a, b].
      final active = intervals
          .where((iv) => iv.start < b && iv.end > a)
          .map((iv) => iv.event)
          .toList();
      if (active.isEmpty) {
        segments.add(TimelineSegment(
          startMinutes: a,
          endMinutes: b,
          type: AnalyticsEventType.idle,
        ));
      } else if (active.length == 1) {
        segments.add(TimelineSegment(
          startMinutes: a,
          endMinutes: b,
          type: active.first.type,
          event: active.first,
        ));
      } else {
        // Несколько одновременных событий — пересечение.
        segments.add(TimelineSegment(
          startMinutes: a,
          endMinutes: b,
          type: AnalyticsEventType.work, // тип не важен — рисуется фиолетовым
          overlappingEvents: List.unmodifiable(active),
          isOverlap: true,
        ));
      }
    }

    // 4. Тики каждые 60 минут.
    final ticks = <int>[];
    for (var t = baseStart; t <= baseEnd; t += 60) {
      ticks.add(t);
    }
    if (ticks.isEmpty || ticks.last != baseEnd) ticks.add(baseEnd);

    return TimelineLayout(
      startMinutes: baseStart,
      endMinutes: baseEnd,
      segments: segments,
      hourlyTicks: ticks,
    );
  }

  static DayShiftType _guessShiftType(
      List<AnalyticsEvent> events, DateTime midnight) {
    var hasNight = false;
    var hasDay = false;
    for (final e in events) {
      final hour = e.startTime.hour;
      if (hour >= 18 || hour < 6) hasNight = true;
      if (hour >= 6 && hour < 18) hasDay = true;
    }
    if (hasNight && !hasDay) return DayShiftType.night;
    if (hasDay && !hasNight) return DayShiftType.day;
    if (hasDay) return DayShiftType.day;
    if (hasNight) return DayShiftType.night;
    return DayShiftType.day;
  }

  static int? _parseHHMM(String raw) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw.trim());
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final mm = int.tryParse(m.group(2)!);
    if (h == null || mm == null) return null;
    if (h < 0 || h > 23 || mm < 0 || mm > 59) return null;
    return h * 60 + mm;
  }
}

class _RawInterval {
  final int start;
  final int end;
  final AnalyticsEvent event;
  const _RawInterval(this.start, this.end, this.event);
}
