import 'package:flutter/material.dart';

import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/day_shift_type.dart';
import '../models/work_schedule_entry.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';

class EmployeeCalendar extends StatelessWidget {
  const EmployeeCalendar({
    super.key,
    required this.month,
    required this.scheduleByDay,
    required this.eventsByDay,
    required this.selectedDay,
    required this.onDaySelected,
    this.now,
  });

  final AnalyticsMonth month;
  final Map<int, WorkScheduleEntry> scheduleByDay;
  final Map<int, List<AnalyticsEvent>> eventsByDay;
  final int? selectedDay;
  final ValueChanged<int> onDaySelected;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final daysCount = month.daysCount;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final cellWidth = w / 7;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(daysCount, (i) {
          final day = i + 1;
          final entry = scheduleByDay[day];
          final events = eventsByDay[day] ?? const <AnalyticsEvent>[];
          final shift = entry?.shiftType ?? _detectShiftFromEvents(events);
          final hasWorkOnOffDay = shift == DayShiftType.off && events.isNotEmpty;
          final missingActivity = _missingActivityAlert(
            entry: entry,
            events: events,
            date: DateTime(month.year, month.month, day),
            now: now ?? DateTime.now(),
          );
          final hasConflictBothShifts = _hasDayNightConflict(events);
          final alert =
              hasWorkOnOffDay || missingActivity || hasConflictBothShifts;
          return SizedBox(
            width: cellWidth - 8,
            child: _CalendarDay(
              day: day,
              shift: shift,
              arrival: entry?.arrivalTime,
              departure: entry?.departureTime,
              isSelected: selectedDay == day,
              alert: alert,
              onTap: () => onDaySelected(day),
            ),
          );
        }),
      );
    });
  }

  DayShiftType _detectShiftFromEvents(List<AnalyticsEvent> events) {
    if (events.isEmpty) return DayShiftType.off;
    var night = false;
    var day = false;
    for (final e in events) {
      final h = e.startTime.hour;
      if (h >= 18 || h < 6) {
        night = true;
      } else {
        day = true;
      }
    }
    if (night && !day) return DayShiftType.night;
    return DayShiftType.day;
  }

  bool _missingActivityAlert({
    required WorkScheduleEntry? entry,
    required List<AnalyticsEvent> events,
    required DateTime date,
    required DateTime now,
  }) {
    if (entry == null || entry.shiftType == DayShiftType.off) return false;
    if (events.isNotEmpty) return false;
    final arrival = entry.arrivalTime ?? '';
    if (arrival.isEmpty) return false;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(arrival);
    if (m == null) return false;
    final shiftStart = DateTime(
      date.year,
      date.month,
      date.day,
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
    );
    if (now.isBefore(shiftStart)) return false;
    final hoursPassed = now.difference(shiftStart).inMinutes;
    return hoursPassed >= AnalyticsConstants.noActivityAlertMinutes;
  }

  bool _hasDayNightConflict(List<AnalyticsEvent> events) {
    var hasDay = false;
    var hasNight = false;
    for (final e in events) {
      final h = e.startTime.hour;
      if (h >= 6 && h < 18) hasDay = true;
      if (h >= 18 || h < 6) hasNight = true;
    }
    return hasDay && hasNight;
  }
}

class _CalendarDay extends StatelessWidget {
  const _CalendarDay({
    required this.day,
    required this.shift,
    required this.arrival,
    required this.departure,
    required this.isSelected,
    required this.alert,
    required this.onTap,
  });
  final int day;
  final DayShiftType shift;
  final String? arrival;
  final String? departure;
  final bool isSelected;
  final bool alert;
  final VoidCallback onTap;

  Color _bg() {
    switch (shift) {
      case DayShiftType.day:
        return const Color(0xFFFACC15);
      case DayShiftType.night:
        return const Color(0xFF111827);
      case DayShiftType.off:
        return const Color(0x3864748B);
    }
  }

  Color _fg() {
    switch (shift) {
      case DayShiftType.day:
        return const Color(0xFF1F2937);
      case DayShiftType.night:
        return Colors.white;
      case DayShiftType.off:
        return AnalyticsColors.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = _fg();
    final bg = _bg();
    final highlightColor = isSelected
        ? AnalyticsColors.blue
        : alert
            ? AnalyticsColors.red
            : AnalyticsColors.line;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        height: 96,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: highlightColor, width: alert ? 2 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                '$day',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                ),
              ),
            ),
            Center(
              child: Text(
                shiftTypeLabel(shift),
                style: TextStyle(color: fg, fontSize: 10),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  arrival ?? '—',
                  style: TextStyle(
                      color: fg, fontSize: 10, fontWeight: FontWeight.bold),
                ),
                Text(
                  departure ?? '—',
                  style: TextStyle(
                      color: fg, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
