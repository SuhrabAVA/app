import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/kpd_calculator.dart';
import '../calculators/rating_calculator.dart';
import '../calculators/timeline_calculator.dart';
import '../models/analytics_event.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/format_utils.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/analytics_states.dart';
import '../widgets/day_events_table.dart';
import '../widgets/timeline_widget.dart';

class WorkplaceDetailScreen extends StatefulWidget {
  const WorkplaceDetailScreen({
    super.key,
    required this.service,
    required this.permission,
    required this.workplaceId,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;
  final String workplaceId;

  @override
  State<WorkplaceDetailScreen> createState() => _WorkplaceDetailScreenState();
}

class _WorkplaceDetailScreenState extends State<WorkplaceDetailScreen> {
  late String _workplaceId;
  int? _selectedDay;

  @override
  void initState() {
    super.initState();
    _workplaceId = widget.workplaceId;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final state = widget.service.state;
        final personnel = context.read<PersonnelProvider>();
        final wp = personnel.workplaceById(_workplaceId);
        if (wp == null) {
          return const AnalyticsShell(
              child: AnalyticsEmptyState(message: 'Рабочее место не найдено'));
        }
        final unit = wp.unit?.trim().isNotEmpty == true ? wp.unit! : 'ед.';
        final allEvents =
            state.events.where((e) => e.workplaceId == _workplaceId).toList();

        final eventsByDay = <int, List<AnalyticsEvent>>{};
        for (final e in allEvents) {
          eventsByDay.putIfAbsent(e.startTime.day, () => []).add(e);
        }
        _selectedDay ??= eventsByDay.keys.isEmpty
            ? 1
            : eventsByDay.keys.reduce((a, b) => a < b ? a : b);
        final daySelected = _selectedDay!;
        final dayEvents = eventsByDay[daySelected] ?? const [];
        final timeline = TimelineCalculator.build(
          day: DateTime(state.month.year, state.month.month, daySelected),
          events: dayEvents,
        );

        final qty = AnalyticsCalculator.totalQty(allEvents);
        final usefulM = AnalyticsCalculator.usefulMinutes(allEvents);
        final speed = usefulM > 0 ? qty / usefulM : 0.0;
        final kpd = KpdCalculator.compute(
          currentSpeed: speed,
          previousMonthsSpeeds:
              state.workplacePreviousSpeeds[_workplaceId] ?? const [],
        );
        final ratings =
            RatingCalculator.buildForWorkplace(eventsForWorkplace: allEvents);

        return AnalyticsShell(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                _toolbar(context, wp.name, unit),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AnalyticsKpiCard(
                          label: 'Сделано',
                          value: '${AnalyticsFormat.decimal(qty)} $unit',
                          sub:
                              'Полезное время: ${AnalyticsFormat.hoursMinutes(usefulM)}'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AnalyticsKpiCard(
                          label: 'Скорость месяца',
                          value:
                              '${AnalyticsFormat.decimal(speed)} $unit/мин',
                          sub: kpd.noBaseline
                              ? 'Нет базы для КПД'
                              : 'Средняя предыдущих: ${AnalyticsFormat.decimal(kpd.previousAverageSpeed)} $unit/мин'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AnalyticsKpiCard(
                          label: 'КПД',
                          value: '${kpd.kpdPercent.round()}%',
                          sub: kpd.noBaseline
                              ? 'Нет базы — показан безопасный fallback'
                              : 'К средней базе всех прошлых месяцев'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AnalyticsCard(
                  title: 'Линия дня',
                  subtitle:
                      'События рабочего места ${wp.name} за ${daySelected.toString().padLeft(2, '0')}.${state.month.month.toString().padLeft(2, '0')}.${state.month.year}',
                  child: TimelineWidget(
                    layout: timeline,
                    workplaceNameOf: (id) =>
                        personnel.workplaceById(id)?.name ?? id,
                    employeeNameOf: (id) {
                      try {
                        final e =
                            personnel.employees.firstWhere((x) => x.id == id);
                        return '${e.lastName} ${e.firstName}'.trim();
                      } catch (_) {
                        return id;
                      }
                    },
                  ),
                ),
                const SizedBox(height: 16),
                AnalyticsCard(
                  title: 'Календарь активности',
                  child: _activityCalendar(state.month.daysCount, eventsByDay),
                ),
                const SizedBox(height: 16),
                AnalyticsCard(
                  title: 'Заказы и работы по рабочему месту',
                  child: DayEventsTable(
                    events: dayEvents,
                    timeline: timeline,
                    workplaceById: {
                      for (final w in personnel.workplaces) w.id: w
                    },
                  ),
                ),
                const SizedBox(height: 16),
                AnalyticsCard(
                  title: 'Рейтинг сотрудников',
                  subtitle:
                      'Сортировка по скорости (кол-во в минуту). Включаются только те, кто работал на этом рабочем месте и сделал > 0.',
                  child: _ratings(personnel, ratings, unit),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolbar(BuildContext context, String name, String unit) {
    final personnel = context.read<PersonnelProvider>();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AnalyticsColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AnalyticsColors.line),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.arrow_back, color: AnalyticsColors.blue),
            label: const Text('Назад',
                style: TextStyle(color: AnalyticsColors.blue)),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Text(
            name,
            style: const TextStyle(
              color: AnalyticsColors.text,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0x4F38BDF8)),
              color: const Color(0x261A8FB5),
            ),
            child: Text('ед.: $unit',
                style: const TextStyle(
                    color: Color(0xFF7DD3FC),
                    fontWeight: FontWeight.w800,
                    fontSize: 11)),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _workplaceId,
            dropdownColor: AnalyticsColors.card2,
            style: const TextStyle(color: AnalyticsColors.text),
            underline: const SizedBox.shrink(),
            items: personnel.workplaces
                .map((w) => DropdownMenuItem(
                      value: w.id,
                      child: Text(w.name),
                    ))
                .toList(),
            onChanged: (id) {
              if (id == null) return;
              setState(() {
                _workplaceId = id;
                _selectedDay = null;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _activityCalendar(int days, Map<int, List<AnalyticsEvent>> eventsByDay) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(days, (i) {
        final day = i + 1;
        final list = eventsByDay[day] ?? const <AnalyticsEvent>[];
        final hasNight = list.any((e) {
          final h = e.startTime.hour;
          return h >= 18 || h < 6;
        });
        final hasDay = list.any((e) {
          final h = e.startTime.hour;
          return h >= 6 && h < 18;
        });
        final color = list.isEmpty
            ? const Color(0x3864748B)
            : hasNight && !hasDay
                ? const Color(0xFF111827)
                : const Color(0xFFFACC15);
        final fg = list.isEmpty
            ? AnalyticsColors.text
            : (hasNight && !hasDay
                ? Colors.white
                : const Color(0xFF1F2937));
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _selectedDay = day),
          child: Container(
            width: 64,
            height: 64,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _selectedDay == day
                    ? AnalyticsColors.blue
                    : AnalyticsColors.line,
                width: _selectedDay == day ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$day',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    )),
                Text(list.isEmpty ? 'нет' : '${list.length} событ.',
                    style: TextStyle(color: fg, fontSize: 9)),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _ratings(PersonnelProvider personnel, List<EmployeeRatingRow> ratings,
      String unit) {
    if (ratings.isEmpty) {
      return const Text('Нет данных для рейтинга.',
          style: TextStyle(color: AnalyticsColors.muted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: List.generate(ratings.length, (i) {
        final row = ratings[i];
        String name = row.employeeId;
        try {
          final e =
              personnel.employees.firstWhere((x) => x.id == row.employeeId);
          name = '${e.lastName} ${e.firstName}'.trim();
        } catch (_) {}
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: const Color(0x0FFFFFFF),
            border: Border.all(color: AnalyticsColors.line),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: const Color(0x2422C55E),
                ),
                child: Text('#${i + 1}',
                    style: const TextStyle(
                        color: Color(0xFFBBF7D0),
                        fontWeight: FontWeight.w900,
                        fontSize: 12)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            color: AnalyticsColors.text,
                            fontWeight: FontWeight.w800)),
                    Text(
                      '${AnalyticsFormat.hoursMinutes(row.usefulMinutes)} / ${AnalyticsFormat.decimal(row.qty)} $unit',
                      style: const TextStyle(
                          color: AnalyticsColors.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Text(
                '${AnalyticsFormat.decimal(row.speed)} $unit/мин',
                style: const TextStyle(
                  color: Color(0xFF86EFAC),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}
