import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/kpd_calculator.dart';
import '../calculators/rating_calculator.dart';
import '../calculators/timeline_calculator.dart';
import '../models/analytics_event.dart';
import '../services/analytics_pdf_export_service.dart';
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
  final _pdfService = AnalyticsPdfExportService();
  bool _pdfLoading = false;

  @override
  void initState() {
    super.initState();
    _workplaceId = widget.workplaceId;
  }

  Future<void> _exportPdf(PersonnelProvider personnel) async {
    if (_pdfLoading) return;
    setState(() => _pdfLoading = true);
    try {
      final path = await _pdfService.exportWorkplaceDetailPdf(
        service: widget.service,
        personnel: personnel,
        workplaceId: _workplaceId,
        selectedDay: _selectedDay,
      );
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PDF сохранён: $path'),
          action: SnackBarAction(
            label: 'Открыть',
            onPressed: () => _pdfService.openPdfFile(path),
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Workplace PDF export failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать PDF: $error')),
      );
    } finally {
      if (mounted) setState(() => _pdfLoading = false);
    }
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

        final setupQty = AnalyticsCalculator.totalSetupQty(allEvents);
        final setupMin = AnalyticsCalculator.setupMinutes(allEvents);
        final pauseCount = AnalyticsCalculator.countEventsOfType(
            allEvents, AnalyticsEventType.pause);
        final pauseMin = AnalyticsCalculator.pauseMinutes(allEvents);
        final problemCount = AnalyticsCalculator.countEventsOfType(
            allEvents, AnalyticsEventType.problem);
        final problemMin = AnalyticsCalculator.problemMinutes(allEvents);
        final orderIds = <String>{};
        for (final e in allEvents) {
          if (e.type == AnalyticsEventType.work && e.orderId.isNotEmpty) {
            orderIds.add(e.orderId);
          }
        }
        final claims = state.claims
            .where((c) => (c.workplaceId ?? '') == _workplaceId)
            .length;

        final mainStack = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnalyticsCard(
              title: 'График активности рабочего места',
              child: _activityCalendar(state.month.daysCount, eventsByDay),
            ),
            const SizedBox(height: 18),
            AnalyticsCard(
              title:
                  'Линия рабочего места: ${daySelected.toString().padLeft(2, '0')}.${state.month.month.toString().padLeft(2, '0')}.${state.month.year}',
              subtitle:
                  'Показывает фактическое время работы рабочего места за выбранный день. При переработке шкала автоматически удлиняется.',
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
            const SizedBox(height: 18),
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
          ],
        );

        final sidePanel = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnalyticsSummaryCard(
              title: 'Итог по рабочему месту',
              green: true,
              children: [
                AnalyticsStatRow(
                    label: 'Количество',
                    value: '${AnalyticsFormat.decimal(qty)} $unit'),
                AnalyticsStatRow(
                    label: 'Время на количество',
                    value: AnalyticsFormat.hoursMinutes(usefulM)),
                AnalyticsStatRow(
                    label: 'Наладки',
                    value:
                        '${AnalyticsFormat.decimal(setupQty)} · ${AnalyticsFormat.hoursMinutes(setupMin)}'),
                AnalyticsStatRow(
                    label: 'Паузы',
                    value:
                        '$pauseCount · ${AnalyticsFormat.hoursMinutes(pauseMin)}'),
                AnalyticsStatRow(
                    label: 'Проблемы',
                    value:
                        '$problemCount · ${AnalyticsFormat.hoursMinutes(problemMin)}'),
                AnalyticsStatRow(
                    label: 'Заказы / претензии',
                    value: '${orderIds.length} / $claims'),
                AnalyticsTotalBox(
                  label: 'КПД',
                  value: '${kpd.kpdPercent.round()}%',
                  note: kpd.noBaseline
                      ? 'нет базы — показан безопасный fallback'
                      : 'скорость месяца / средняя прошлых месяцев',
                ),
              ],
            ),
            const SizedBox(height: 18),
            AnalyticsSummaryCard(
              title: 'Рейтинг сотрудников',
              subtitle:
                  'Сортировка по скорости (кол-во в минуту). Включаются только те, кто работал на этом рабочем месте и сделал > 0.',
              children: [_ratings(personnel, ratings, unit)],
            ),
          ],
        );

        return AnalyticsShell(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 14),
                _toolbar(context, wp.name, unit),
                const SizedBox(height: 18),
                AnalyticsDetailLayout(
                  main: mainStack,
                  side: sidePanel,
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

    final left = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnalyticsBackLink(
          label: 'Назад к рабочим местам',
          onTap: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(height: 6),
        Text(
          name,
          style: const TextStyle(
            color: AnalyticsColors.text,
            fontSize: 30,
            fontWeight: FontWeight.w900,
            letterSpacing: -1,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 8),
        Text('единица измерения: $unit',
            style: const TextStyle(
                color: AnalyticsColors.muted, fontSize: 13)),
      ],
    );

    final controls = Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        AnalyticsFilterGroup(
          label: 'Быстро сменить рабочее место',
          child: AnalyticsInputShell(
            child: DropdownButton<String>(
              value: _workplaceId,
              isExpanded: true,
              dropdownColor: AnalyticsColors.card2,
              style: const TextStyle(color: AnalyticsColors.text),
              underline: const SizedBox.shrink(),
              icon:
                  const Icon(Icons.expand_more, color: AnalyticsColors.muted),
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
          ),
        ),
        AnalyticsPdfButton(
          loading: _pdfLoading,
          onPressed: () => _exportPdf(personnel),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [left, const SizedBox(height: 16), controls],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: left),
            const SizedBox(width: 16),
            controls,
          ],
        );
      },
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