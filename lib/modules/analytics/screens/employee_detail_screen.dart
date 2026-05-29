import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/employee_model.dart';
import '../../personnel/personnel_provider.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/salary_calculator.dart';
import '../calculators/timeline_calculator.dart';
import '../models/analytics_event.dart';
import '../models/salary_adjustments.dart';
import '../services/analytics_pdf_export_service.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';
import '../widgets/analytics_calendar.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/analytics_states.dart';
import '../widgets/day_events_table.dart';
import '../widgets/employee_workplace_strip.dart';
import '../widgets/timeline_widget.dart';
import 'analytics_access_denied_screen.dart';

class EmployeeDetailScreen extends StatefulWidget {
  const EmployeeDetailScreen({
    super.key,
    required this.service,
    required this.permission,
    required this.employeeId,
    this.hideBackButton = false,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;
  final String employeeId;
  final bool hideBackButton;

  @override
  State<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends State<EmployeeDetailScreen> {
  late String _employeeId;
  int? _selectedDay;
  String _workplaceFilter = AnalyticsConstants.allWorkplaces;
  final _pdfService = AnalyticsPdfExportService();
  bool _pdfLoading = false;

  @override
  void initState() {
    super.initState();
    _employeeId = widget.employeeId;
  }

  Future<void> _exportPdf(PersonnelProvider personnel) async {
    if (_pdfLoading) return;
    setState(() => _pdfLoading = true);
    try {
      final path = await _pdfService.exportEmployeeDetailPdf(
        service: widget.service,
        personnel: personnel,
        employeeId: _employeeId,
        selectedDay: _selectedDay,
        workplaceFilter: _workplaceFilter,
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
      debugPrint('Employee PDF export failed: $error');
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
    if (!widget.permission.canViewEmployee(_employeeId)) {
      return const AnalyticsAccessDeniedScreen();
    }
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final state = widget.service.state;
        if (state.loading && state.events.isEmpty) {
          return const AnalyticsShell(
              child: AnalyticsLoadingState());
        }
        if (state.error != null) {
          return AnalyticsShell(
            child: AnalyticsErrorState(
              message: 'Не удалось загрузить данные.\n${state.error}',
              onRetry: () => widget.service.refresh(),
            ),
          );
        }
        final personnel = context.read<PersonnelProvider>();
        EmployeeModel? employee;
        try {
          employee = personnel.employees.firstWhere((e) => e.id == _employeeId);
        } catch (_) {
          employee = null;
        }
        if (employee == null) {
          return const AnalyticsShell(
              child: AnalyticsEmptyState(message: 'Сотрудник не найден'));
        }

        final allEvents = state.events.where((e) => e.employeeId == _employeeId).toList();
        // workplace filter
        final filtered = _workplaceFilter == AnalyticsConstants.allWorkplaces
            ? allEvents
            : allEvents.where((e) => e.workplaceId == _workplaceFilter).toList();

        final eventsByDay = <int, List<AnalyticsEvent>>{};
        for (final e in filtered) {
          eventsByDay
              .putIfAbsent(e.startTime.day, () => [])
              .add(e);
        }
        // Если selectedDay не задан — берём первый день с активностью или 1.
        _selectedDay ??= eventsByDay.keys.isEmpty
            ? 1
            : eventsByDay.keys.reduce((a, b) => a < b ? a : b);

        final daySelected = _selectedDay!;
        final dayEvents = eventsByDay[daySelected] ?? const [];
        final timeline = TimelineCalculator.build(
          day: DateTime(state.month.year, state.month.month, daySelected),
          events: dayEvents,
          schedule: state.schedules[_employeeId]?[daySelected],
        );

        // workplaceSummary
        final byWorkplace = <String, List<AnalyticsEvent>>{};
        for (final e in allEvents) {
          byWorkplace.putIfAbsent(e.workplaceId, () => []).add(e);
        }
        final claimsByWp = <String, int>{};
        for (final c in state.claims) {
          if (c.employeeId != _employeeId) continue;
          claimsByWp[c.workplaceId ?? ''] =
              (claimsByWp[c.workplaceId ?? ''] ?? 0) + 1;
        }
        final summaries = byWorkplace.entries.map((entry) {
          final wp = personnel.workplaceById(entry.key);
          return buildWorkplaceSummary(
            workplaceId: entry.key,
            workplace: wp,
            events: entry.value,
            claims: claimsByWp[entry.key] ?? 0,
          );
        }).toList()
          ..sort((a, b) => b.workMinutes.compareTo(a.workMinutes));

        final adj = state.adjustments[_employeeId] ??
            SalaryAdjustments.zero(_employeeId, state.month.firstDay);
        final breakdown = SalaryCalculator.compute(
          events: allEvents,
          coefficients: state.coefficients,
          settings: state.settings,
          adjustments: adj,
          halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
        );

        final usefulMin = AnalyticsCalculator.usefulMinutes(allEvents);

        return AnalyticsShell(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                _toolbar(context, personnel, employee, allEvents, breakdown),
                const SizedBox(height: 12),
                _kpis(employee, allEvents, breakdown, usefulMin),
                const SizedBox(height: 16),
                AnalyticsCard(
                  title: 'Рабочие места сотрудника',
                  subtitle:
                      'Прокручивайте вбок. Клик по карточке фильтрует timeline и таблицу ниже.',
                  child: EmployeeWorkplaceStrip(
                    rows: summaries,
                    activeFilter: _workplaceFilter,
                    onChangeFilter: (id) =>
                        setState(() => _workplaceFilter = id),
                  ),
                ),
                const SizedBox(height: 16),
                AnalyticsCard(
                  title: 'График работы за месяц',
                  subtitle:
                      'Цвет показывает тип смены: жёлтый — день, тёмный — ночь, серый — выходной.',
                  child: EmployeeCalendar(
                    month: state.month,
                    scheduleByDay: state.schedules[_employeeId] ?? const {},
                    eventsByDay: eventsByDay,
                    selectedDay: daySelected,
                    onDaySelected: (d) => setState(() => _selectedDay = d),
                  ),
                ),
                const SizedBox(height: 16),
                AnalyticsCard(
                  title:
                      'Линия дня: ${daySelected.toString().padLeft(2, '0')}.${state.month.month.toString().padLeft(2, '0')}.${state.month.year}',
                  subtitle:
                      'Показывает фактическое время работы. Если активность началась раньше — шкала автоматически удлиняется.',
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
                  title: 'Заказы и работы выбранного дня',
                  child: DayEventsTable(
                    events: dayEvents,
                    timeline: timeline,
                    workplaceById: {
                      for (final w in personnel.workplaces) w.id: w
                    },
                  ),
                ),
                if (widget.permission.canViewFinance) ...[
                  const SizedBox(height: 16),
                  _salaryCard(breakdown),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolbar(BuildContext context, PersonnelProvider personnel,
      EmployeeModel employee, List<AnalyticsEvent> events, SalaryBreakdown brk) {
    final state = widget.service.state;
    final statusName = state.statuses
        .where((s) =>
            s.id == (state.employeeStatusIds[employee.id] ?? ''))
        .map((s) => s.name)
        .firstWhere((_) => true, orElse: () => '');
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
        runSpacing: 10,
        children: [
          if (!widget.hideBackButton)
            TextButton.icon(
              icon: const Icon(Icons.arrow_back, color: AnalyticsColors.blue),
              label: const Text('Назад',
                  style: TextStyle(color: AnalyticsColors.blue)),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          Text(
            '${employee.lastName} ${employee.firstName}'.trim(),
            style: const TextStyle(
              color: AnalyticsColors.text,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (statusName.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0x4F38BDF8)),
                color: const Color(0x261A8FB5),
              ),
              child: Text(statusName,
                  style: const TextStyle(
                      color: Color(0xFF7DD3FC),
                      fontWeight: FontWeight.w800,
                      fontSize: 11)),
            ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _pdfLoading ? null : () => _exportPdf(personnel),
            icon: _pdfLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined),
            label: Text(_pdfLoading ? 'Создаём PDF…' : 'Скачать PDF'),
          ),
          if (widget.permission.canViewAllEmployees)
            DropdownButton<String>(
              value: _employeeId,
              dropdownColor: AnalyticsColors.card2,
              style: const TextStyle(color: AnalyticsColors.text),
              underline: const SizedBox.shrink(),
              items: personnel.employees
                  .where((e) => !e.isFired)
                  .map((e) => DropdownMenuItem(
                        value: e.id,
                        child: Text('${e.lastName} ${e.firstName}'.trim()),
                      ))
                  .toList(),
              onChanged: (id) {
                if (id == null) return;
                setState(() {
                  _employeeId = id;
                  _selectedDay = null;
                  _workplaceFilter = AnalyticsConstants.allWorkplaces;
                });
              },
            ),
        ],
      ),
    );
  }

  Widget _kpis(EmployeeModel emp, List<AnalyticsEvent> events,
      SalaryBreakdown brk, int usefulMin) {
    return Row(
      children: [
        Expanded(
            child: AnalyticsKpiCard(
                label: 'Смены',
                value: '${brk.shiftsTotal}',
                sub: '${brk.dayShifts} день · ${brk.nightShifts} ночь')),
        const SizedBox(width: 12),
        Expanded(
            child: AnalyticsKpiCard(
                label: 'Полезное время',
                value: AnalyticsFormat.hoursMinutes(usefulMin),
                sub: 'работа + наладка')),
        const SizedBox(width: 12),
        Expanded(
            child: AnalyticsKpiCard(
                label: 'Сделано',
                value: AnalyticsFormat.decimal(
                    AnalyticsCalculator.totalQty(events)),
                sub:
                    'паузы ${AnalyticsCalculator.pauseMinutes(events)} мин · проблемы ${AnalyticsCalculator.problemMinutes(events)} мин')),
        if (widget.permission.canViewFinance) ...[
          const SizedBox(width: 12),
          Expanded(
              child: AnalyticsKpiCard(
                  label: 'Итог ЗП',
                  value: AnalyticsFormat.money(brk.total),
                  sub: 'после удержаний')),
        ],
      ],
    );
  }

  Widget _salaryCard(SalaryBreakdown brk) {
    final state = widget.service.state;
    final adj = state.adjustments[_employeeId] ??
        SalaryAdjustments.zero(_employeeId, state.month.firstDay);

    return AnalyticsCard(
      title: 'Расчёт зарплаты',
      subtitle: state.settings.nightPercent > 0
          ? 'Ночные смены оплачиваются по ${state.settings.nightPercent.toStringAsFixed(0)}% от средней суммы за смену.'
          : 'Ночные смены пока не настроены.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _salaryRow('Сдельно', AnalyticsFormat.money(brk.pieceSalary)),
          _salaryRow('Средняя ЗП за смену',
              AnalyticsFormat.money(brk.averageShiftSalary)),
          _salaryRow(
              'Ночные', AnalyticsFormat.money(brk.nightBonus)),
          _salaryRow('Питание (удержание)',
              '−${AnalyticsFormat.money(brk.mealDeduction)}'),
          const Divider(color: AnalyticsColors.line),
          _adjustmentField('Компенсация', adj.compensation, (v) {
            widget.service.saveSalaryAdjustments(
                adj.copyWith(compensation: v));
          }),
          _adjustmentField('Соц. отчисления', adj.social, (v) {
            widget.service.saveSalaryAdjustments(adj.copyWith(social: v));
          }),
          _adjustmentField('Аванс', adj.advance, (v) {
            widget.service.saveSalaryAdjustments(adj.copyWith(advance: v));
          }),
          _adjustmentField('ЗП безнал', adj.cashless, (v) {
            widget.service.saveSalaryAdjustments(adj.copyWith(cashless: v));
          }),
          _adjustmentField('Дисциплина', adj.discipline, (v) {
            widget.service
                .saveSalaryAdjustments(adj.copyWith(discipline: v));
          }),
          _adjustmentField('Браки', adj.defect, (v) {
            widget.service.saveSalaryAdjustments(adj.copyWith(defect: v));
          }),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF86EFAC), Color(0xFF22C55E)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('К выплате',
                    style: TextStyle(
                      color: Color(0xFF052E16),
                      fontWeight: FontWeight.w900,
                    )),
                const SizedBox(height: 6),
                Text(AnalyticsFormat.money(brk.total),
                    style: const TextStyle(
                      color: Color(0xFF052E16),
                      fontWeight: FontWeight.w900,
                      fontSize: 28,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _salaryRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: AnalyticsColors.muted)),
            ),
            Text(value,
                style: const TextStyle(
                    color: AnalyticsColors.text,
                    fontWeight: FontWeight.w900)),
          ],
        ),
      );

  Widget _adjustmentField(
      String label, double value, ValueChanged<double> onChanged) {
    final ctrl =
        TextEditingController(text: AnalyticsFormat.decimal(value, precision: 0));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(color: AnalyticsColors.muted)),
          ),
          SizedBox(
            width: 130,
            child: TextField(
              controller: ctrl,
              enabled: widget.permission.canEdit,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: AnalyticsColors.text, fontWeight: FontWeight.w800),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => onChanged(_parseDouble(v)),
              onEditingComplete: () => onChanged(_parseDouble(ctrl.text)),
            ),
          ),
        ],
      ),
    );
  }

  double _parseDouble(String s) {
    final n = s.replaceAll(',', '.').trim();
    return double.tryParse(n) ?? 0;
  }
}
