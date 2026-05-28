import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../personnel/personnel_provider.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/day_shift_type.dart';
import '../models/work_schedule_entry.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';

class ScheduleGrid extends StatelessWidget {
  const ScheduleGrid({
    super.key,
    required this.service,
    required this.personnel,
    required this.canEdit,
  });

  final AnalyticsService service;
  final PersonnelProvider personnel;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final state = service.state;
    final month = state.month;
    final days = List.generate(month.daysCount, (i) => i + 1);

    // events by employee+day для подсветки
    final activityByEmpDay = <String, Map<int, List<AnalyticsEvent>>>{};
    for (final e in state.events) {
      activityByEmpDay
          .putIfAbsent(e.employeeId, () => {})
          .putIfAbsent(e.startTime.day, () => [])
          .add(e);
    }

    final activeEmployees =
        personnel.employees.where((e) => !e.isFired).toList()
          ..sort((a, b) => ('${a.lastName} ${a.firstName}')
              .compareTo('${b.lastName} ${b.firstName}'));

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite
          ? math.max(constraints.maxWidth, 2400.0)
          : 2400.0;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(days),
              for (final emp in activeEmployees)
                _row(context, month, emp, days, state.schedules,
                    activityByEmpDay),
            ],
          ),
        ),
      );
    });
  }

  Widget _header(List<int> days) {
    return Container(
      decoration: const BoxDecoration(color: Color(0xFF121A2E)),
      child: Row(
        children: [
          SizedBox(
            width: 220,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: const Text('Сотрудник',
                  style: TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontWeight: FontWeight.w800,
                      fontSize: 11)),
            ),
          ),
          for (final d in days)
            SizedBox(
              width: 74,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '$d',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontWeight: FontWeight.w800,
                      fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    AnalyticsMonth month,
    employee,
    List<int> days,
    Map<String, Map<int, WorkScheduleEntry>> schedules,
    Map<String, Map<int, List<AnalyticsEvent>>> activity,
  ) {
    final byDay = schedules[employee.id] ?? <int, WorkScheduleEntry>{};
    return Container(
      decoration: BoxDecoration(
        color: AnalyticsColors.card2.withOpacity(0.55),
        border: Border(bottom: BorderSide(color: AnalyticsColors.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 220,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${employee.lastName} ${employee.firstName}'.trim(),
                style: const TextStyle(
                  color: AnalyticsColors.text,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          for (final d in days)
            SizedBox(
              width: 74,
              child: _Cell(
                month: month,
                employeeId: employee.id,
                day: d,
                entry: byDay[d],
                activityForDay: activity[employee.id]?[d] ?? const [],
                onCycle: canEdit
                    ? () => _cycle(month, employee.id, d, byDay[d])
                    : null,
                onEditTime: canEdit
                    ? (field, value) =>
                        _editTime(month, employee.id, d, byDay[d], field, value)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _cycle(
      AnalyticsMonth month, String empId, int day, WorkScheduleEntry? existing) async {
    final current = existing?.shiftType ?? DayShiftType.off;
    DayShiftType next;
    switch (current) {
      case DayShiftType.day:
        next = DayShiftType.night;
        break;
      case DayShiftType.night:
        next = DayShiftType.off;
        break;
      case DayShiftType.off:
        next = DayShiftType.day;
        break;
    }
    final defaults = WorkScheduleEntry.defaultsFor(next);
    final entry = WorkScheduleEntry(
      id: existing?.id ?? '',
      employeeId: empId,
      workDate: DateTime(month.year, month.month, day),
      shiftType: next,
      arrivalTime: defaults.$1,
      departureTime: defaults.$2,
    );
    await service.saveScheduleCell(
      employeeId: empId,
      date: entry.workDate,
      entry: entry,
    );
  }

  Future<void> _editTime(
    AnalyticsMonth month,
    String empId,
    int day,
    WorkScheduleEntry? existing,
    String field,
    String value,
  ) async {
    final defaults = WorkScheduleEntry.defaultsFor(
        existing?.shiftType ?? DayShiftType.day);
    final arrival =
        field == 'arrival' ? value : (existing?.arrivalTime ?? defaults.$1);
    final departure = field == 'departure'
        ? value
        : (existing?.departureTime ?? defaults.$2);
    final entry = WorkScheduleEntry(
      id: existing?.id ?? '',
      employeeId: empId,
      workDate: DateTime(month.year, month.month, day),
      shiftType: existing?.shiftType ?? DayShiftType.day,
      arrivalTime: arrival,
      departureTime: departure,
    );
    await service.saveScheduleCell(
      employeeId: empId,
      date: entry.workDate,
      entry: entry,
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.month,
    required this.employeeId,
    required this.day,
    required this.entry,
    required this.activityForDay,
    required this.onCycle,
    required this.onEditTime,
  });

  final AnalyticsMonth month;
  final String employeeId;
  final int day;
  final WorkScheduleEntry? entry;
  final List<AnalyticsEvent> activityForDay;
  final VoidCallback? onCycle;
  final void Function(String field, String value)? onEditTime;

  @override
  Widget build(BuildContext context) {
    final shift = entry?.shiftType ?? DayShiftType.off;
    final hasWorkOnOffDay = shift == DayShiftType.off && activityForDay.isNotEmpty;
    final arrival = entry?.arrivalTime ?? '';
    final departure = entry?.departureTime ?? '';

    final bg = switch (shift) {
      DayShiftType.day => const Color(0xFFFACC15),
      DayShiftType.night => const Color(0xFF0B1220),
      DayShiftType.off => const Color(0x44475569),
    };
    final fg = switch (shift) {
      DayShiftType.day => const Color(0xFF101827),
      DayShiftType.night => Colors.white,
      DayShiftType.off => AnalyticsColors.text,
    };

    return Padding(
      padding: const EdgeInsets.all(3),
      child: GestureDetector(
        onTap: onCycle,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasWorkOnOffDay
                  ? AnalyticsColors.red
                  : AnalyticsColors.line,
              width: hasWorkOnOffDay ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$day',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              Text(
                shiftTypeLabel(shift),
                style: TextStyle(color: fg, fontSize: 9),
              ),
              const SizedBox(height: 2),
              _TimePill(
                value: arrival,
                hint: '↘',
                color: fg,
                enabled: onEditTime != null,
                onSubmitted: (v) => onEditTime?.call('arrival', v),
              ),
              _TimePill(
                value: departure,
                hint: '↗',
                color: fg,
                enabled: onEditTime != null,
                onSubmitted: (v) => onEditTime?.call('departure', v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimePill extends StatefulWidget {
  const _TimePill({
    required this.value,
    required this.hint,
    required this.color,
    required this.enabled,
    required this.onSubmitted,
  });

  final String value;
  final String hint;
  final Color color;
  final bool enabled;
  final ValueChanged<String> onSubmitted;

  @override
  State<_TimePill> createState() => _TimePillState();
}

class _TimePillState extends State<_TimePill> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _TimePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Container(
        height: 18,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const SizedBox(width: 4),
            Text(
              widget.hint,
              style: TextStyle(
                color: widget.color,
                fontWeight: FontWeight.w900,
                fontSize: 9,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                enabled: widget.enabled,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 0),
                ),
                onSubmitted: widget.onSubmitted,
                onEditingComplete: () =>
                    widget.onSubmitted(_ctrl.text.trim()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
