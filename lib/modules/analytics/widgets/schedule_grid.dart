import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../../personnel/personnel_provider.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/day_shift_type.dart';
import '../models/work_schedule_entry.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/h_scroll_sync.dart';

const double _employeeColumnWidth = 220;
const double _dayColumnWidth = 74;

class ScheduleGrid extends StatefulWidget {
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
  State<ScheduleGrid> createState() => _ScheduleGridState();
}

class _ScheduleGridState extends State<ScheduleGrid> {
  // One synced horizontal-scroll group for header + all rows.
  final HScrollSync _sync = HScrollSync();
  final Map<int, ScrollController> _ctrlCache = {};

  ScrollController _ctrl(int key) =>
      _ctrlCache.putIfAbsent(key, () => _sync.acquire());

  @override
  void dispose() {
    _sync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state;
    final month = state.month;
    final days = List.generate(month.daysCount, (i) => i + 1);

    // Events grouped by employee + day for highlight.
    final activityByEmpDay = <String, Map<int, List<AnalyticsEvent>>>{};
    for (final e in state.events) {
      activityByEmpDay
          .putIfAbsent(e.employeeId, () => {})
          .putIfAbsent(e.startTime.day, () => [])
          .add(e);
    }

    final activeEmployees = widget.personnel.employees
        .where((e) => !e.isFired)
        .toList()
      ..sort((a, b) => ('${a.lastName} ${a.firstName}')
          .compareTo('${b.lastName} ${b.firstName}'));

    // Тащить график мышью: по умолчанию Flutter принимает drag только от
    // пальца, поэтому на ПК сетка дней не прокручивалась вбок.
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header row ───────────────────────────────────────────────────
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Sticky "Сотрудник" label
                Container(
                  width: _employeeColumnWidth,
                  decoration: const BoxDecoration(color: AnalyticsColors.bg2),
                  padding: const EdgeInsets.all(12),
                  child: const Text(
                    'Сотрудник',
                    style: TextStyle(
                      color: AnalyticsColors.tableHeaderText,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
                // Scrollable day-number headers
                Expanded(
                  child: SingleChildScrollView(
                    controller: _ctrl(-1),
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: Row(
                      children: days
                          .map((d) => Container(
                                width: _dayColumnWidth,
                                color: AnalyticsColors.bg2,
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  '$d',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AnalyticsColors.tableHeaderText,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 11,
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Data rows ────────────────────────────────────────────────────
          ...activeEmployees.asMap().entries.map((entry) {
            final i = entry.key;
            final emp = entry.value;
            return _buildRow(
              context,
              month,
              emp,
              days,
              state.schedules,
              activityByEmpDay,
              rowIndex: i,
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    AnalyticsMonth month,
    dynamic employee,
    List<int> days,
    Map<String, Map<int, WorkScheduleEntry>> schedules,
    Map<String, Map<int, List<AnalyticsEvent>>> activity, {
    required int rowIndex,
  }) {
    final byDay = schedules[employee.id] ?? <int, WorkScheduleEntry>{};

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sticky employee name
          Container(
            width: _employeeColumnWidth,
            decoration: BoxDecoration(
              color: AnalyticsColors.card2.withOpacity(0.55),
              border: Border(bottom: BorderSide(color: AnalyticsColors.line)),
            ),
            padding: const EdgeInsets.all(12),
            child: Text(
              '${employee.lastName} ${employee.firstName}'.trim(),
              style: const TextStyle(
                color: AnalyticsColors.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Scrollable day cells
          Expanded(
            child: SingleChildScrollView(
              controller: _ctrl(rowIndex),
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Container(
                decoration: BoxDecoration(
                  color: AnalyticsColors.card2.withOpacity(0.55),
                  border:
                      Border(bottom: BorderSide(color: AnalyticsColors.line)),
                ),
                child: Row(
                  children: days
                      .map((d) => SizedBox(
                            width: _dayColumnWidth,
                            child: _Cell(
                              month: month,
                              employeeId: employee.id,
                              day: d,
                              entry: byDay[d],
                              activityForDay:
                                  activity[employee.id]?[d] ?? const [],
                              onCycle: widget.canEdit
                                  ? () =>
                                      _cycle(month, employee.id, d, byDay[d])
                                  : null,
                              onEditTime: widget.canEdit
                                  ? (field, value) => _editTime(month,
                                      employee.id, d, byDay[d], field, value)
                                  : null,
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Актуальная запись ячейки из состояния сервиса. Замыкания строк грида
  /// захватывают карту byDay на момент build — между сохранением первого
  /// поля времени и вводом второго она может устареть, и тогда второй
  /// upsert откатил бы первое поле к дефолту смены.
  WorkScheduleEntry? _freshEntry(
          String empId, int day, WorkScheduleEntry? fallback) =>
      widget.service.state.schedules[empId]?[day] ?? fallback;

  Future<void> _cycle(AnalyticsMonth month, String empId, int day,
      WorkScheduleEntry? stale) async {
    final existing = _freshEntry(empId, day, stale);
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
    // Произвольный интервал (время, отличное от дефолтов текущего типа
    // смены) переживает клик-цикл день↔ночь: клик по ячейке не должен
    // «округлять» кастомный график обратно к стандартной смене.
    // Переключение на выходной время очищает.
    final oldDefaults = WorkScheduleEntry.defaultsFor(current);
    final keepCustom = next != DayShiftType.off &&
        existing != null &&
        (existing.arrivalTime != oldDefaults.$1 ||
            existing.departureTime != oldDefaults.$2);
    final entry = WorkScheduleEntry(
      id: existing?.id ?? '',
      employeeId: empId,
      workDate: DateTime(month.year, month.month, day),
      shiftType: next,
      arrivalTime: keepCustom ? existing.arrivalTime : defaults.$1,
      departureTime: keepCustom ? existing.departureTime : defaults.$2,
    );
    await widget.service.saveScheduleCell(
      employeeId: empId,
      date: entry.workDate,
      entry: entry,
    );
  }

  Future<void> _editTime(
    AnalyticsMonth month,
    String empId,
    int day,
    WorkScheduleEntry? stale,
    String field,
    String value,
  ) async {
    final existing = _freshEntry(empId, day, stale);
    final defaults =
        WorkScheduleEntry.defaultsFor(existing?.shiftType ?? DayShiftType.day);
    // Пустой ввод = «очистить время»: в колонку TIME должен уйти null,
    // пустая строка не пройдёт кастинг на стороне Postgres.
    final String? normalized = value.isEmpty ? null : value;
    final arrival = field == 'arrival'
        ? normalized
        : (existing?.arrivalTime ?? defaults.$1);
    final departure = field == 'departure'
        ? normalized
        : (existing?.departureTime ?? defaults.$2);
    final entry = WorkScheduleEntry(
      id: existing?.id ?? '',
      employeeId: empId,
      workDate: DateTime(month.year, month.month, day),
      shiftType: existing?.shiftType ?? DayShiftType.day,
      arrivalTime: arrival,
      departureTime: departure,
    );
    await widget.service.saveScheduleCell(
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
    final hasWorkOnOffDay =
        shift == DayShiftType.off && activityForDay.isNotEmpty;
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
              color:
                  hasWorkOnOffDay ? AnalyticsColors.red : AnalyticsColors.line,
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
                  fontWeight: FontWeight.w600,
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

/// Нормализует ввод времени к «HH:MM». Допускает «H:MM» и разделитель
/// «.» вместо «:». Возвращает null, если строка — не корректное время;
/// произвольные значения (13:00, 15:45 и т.п.) проходят как есть.
String? normalizeScheduleTime(String raw) {
  final m = RegExp(r'^\s*(\d{1,2})[:.](\d{2})\s*$').firstMatch(raw);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final mm = int.parse(m.group(2)!);
  if (h > 23 || mm > 59) return null;
  return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
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
  late FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
    // На десктопе клик мимо поля не вызывает onSubmitted/onEditingComplete —
    // без сохранения по потере фокуса введённое время молча пропадало и
    // ячейка откатывалась к дефолту смены (08:00–20:00).
    _focus = FocusNode();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _submit();
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
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// Валидация перед сохранением: наверх уходит либо нормализованное
  /// «HH:MM», либо пустая строка (очистка). Некорректный ввод откатывается
  /// к последнему сохранённому значению и в Supabase не попадает.
  void _submit() {
    if (!mounted) return;
    final raw = _ctrl.text.trim();
    if (raw.isEmpty) {
      if (widget.value.isNotEmpty) widget.onSubmitted('');
      return;
    }
    final normalized = normalizeScheduleTime(raw);
    if (normalized == null) {
      _ctrl.text = widget.value;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Время — в формате ЧЧ:ММ, например 13:00'),
        ),
      );
      return;
    }
    _ctrl.text = normalized;
    if (normalized != widget.value) widget.onSubmitted(normalized);
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
                fontWeight: FontWeight.w600,
                fontSize: 9,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                enabled: widget.enabled,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 0),
                ),
                onSubmitted: (_) => _submit(),
                onEditingComplete: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
