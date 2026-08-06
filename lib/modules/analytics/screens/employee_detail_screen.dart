import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/employee_model.dart';
import '../../personnel/personnel_provider.dart';
import '../../tasks/task_comment_presentation.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/salary_calculator.dart';
import '../calculators/timeline_calculator.dart';
import '../models/analytics_day_comment.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import '../models/pay_type.dart';
import '../models/salary_adjustments.dart';
import '../services/analytics_pdf_export_service.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';
import '../widgets/analytics_calendar.dart';
import '../widgets/analytics_month_picker.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/claims_list_dialog.dart';
import '../widgets/analytics_states.dart';
import '../widgets/day_events_table.dart';
import '../widgets/employee_workplace_strip.dart';
import '../widgets/incident_orders_dialog.dart';
import '../widgets/timeline_widget.dart';
import 'analytics_access_denied_screen.dart';

class EmployeeDetailScreen extends StatefulWidget {
  const EmployeeDetailScreen({
    super.key,
    required this.service,
    required this.permission,
    required this.employeeId,
    this.hideBackButton = false,
    this.onMonthChanged,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;
  final String employeeId;
  final bool hideBackButton;

  /// Если задан — в тулбаре показывается выбор месяца (selfView сотрудника:
  /// у него нет общей оболочки аналитики с пикером месяца, как у лида).
  final ValueChanged<AnalyticsMonth>? onMonthChanged;

  @override
  State<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends State<EmployeeDetailScreen> {
  late String _employeeId;
  int? _selectedDay;
  String _workplaceFilter = AnalyticsConstants.allWorkplaces;
  final _pdfService = AnalyticsPdfExportService();
  bool _pdfLoading = false;
  bool _statementLoading = false;

  @override
  void initState() {
    super.initState();
    _employeeId = widget.employeeId;
  }

  Future<void> _exportPdf(PersonnelProvider personnel) async {
    // Защита в глубину: PDF содержит финансовый блок, сотруднику запрещён.
    if (!widget.permission.canExportPdf) return;
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

  /// Ведомость за месяц — один лист А4 (см. Фазу 6). Гейт тот же, что у
  /// детального PDF: документ целиком финансовый.
  Future<void> _exportStatement(PersonnelProvider personnel) async {
    if (!widget.permission.canExportPdf) return;
    if (_statementLoading) return;
    setState(() => _statementLoading = true);
    try {
      final path = await _pdfService.exportEmployeeSalaryStatementPdf(
        service: widget.service,
        personnel: personnel,
        employeeId: _employeeId,
      );
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ведомость сохранена: $path'),
          action: SnackBarAction(
            label: 'Открыть',
            onPressed: () => _pdfService.openPdfFile(path),
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Salary statement export failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать ведомость: $error')),
      );
    } finally {
      if (mounted) setState(() => _statementLoading = false);
    }
  }

  /// Разбор простоев рабочего места: заказы с паузами/проблемами, а внутри
  /// заказа — его комментарии. Берём события за весь месяц (не только за
  /// выбранный день) — иначе разбор простоя зависел бы от того, какой день
  /// открыт в календаре.
  void _openIncidents({
    required BuildContext context,
    required String workplaceId,
    required AnalyticsEventType type,
    required List<AnalyticsEvent> events,
    required AnalyticsState state,
    required PersonnelProvider personnel,
  }) {
    final incidents = events
        .where((e) => e.workplaceId == workplaceId && e.type == type)
        .toList();
    final workplaceName =
        personnel.workplaceById(workplaceId)?.name ?? workplaceId;
    showDialog<void>(
      context: context,
      builder: (_) => IncidentOrdersDialog(
        title: type == AnalyticsEventType.problem ? 'Проблемы' : 'Паузы',
        workplaceName: workplaceName,
        type: type,
        events: incidents,
        // Комментарии всех участников по заказу, а не только свои: причину
        // простоя мог записать сменщик или мастер.
        comments: state.dayComments,
        employeeNameOf: (id) {
          try {
            final e = personnel.employees.firstWhere((x) => x.id == id);
            final name = '${e.lastName} ${e.firstName}'.trim();
            return name.isEmpty ? id : name;
          } catch (_) {
            return id;
          }
        },
        workplaceNameOf: (id) => personnel.workplaceById(id)?.name ?? '',
      ),
    );
  }

  /// Точечные маркеры комментариев/событий на линии дня (только отображение).
  List<TimelineMarker> _commentMarkers(
    List<AnalyticsDayComment> comments,
    int daySelected,
    AnalyticsState state,
  ) {
    final midnight = DateTime(state.month.year, state.month.month, daySelected);
    String hhmm(DateTime dt) =>
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return [
      for (final c in comments)
        TimelineMarker(
          minutes: c.timestamp.difference(midnight).inMinutes,
          color: taskCommentColor(c.type, c.text),
          tooltip:
              '${hhmm(c.timestamp)} — ${describeTaskComment(c.type, c.text)}',
        ),
    ];
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
          return const AnalyticsShell(child: AnalyticsLoadingState());
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

        final allEvents =
            state.events.where((e) => e.employeeId == _employeeId).toList();
        // workplace filter
        final filtered = _workplaceFilter == AnalyticsConstants.allWorkplaces
            ? allEvents
            : allEvents
                .where((e) => e.workplaceId == _workplaceFilter)
                .toList();

        final eventsByDay = <int, List<AnalyticsEvent>>{};
        for (final e in filtered) {
          eventsByDay.putIfAbsent(e.startTime.day, () => []).add(e);
        }
        // Если selectedDay не задан — берём первый день с активностью или 1.
        _selectedDay ??= eventsByDay.keys.isEmpty
            ? 1
            : eventsByDay.keys.reduce((a, b) => a < b ? a : b);

        final daySelected = _selectedDay!;
        final dayEvents = eventsByDay[daySelected] ?? const [];
        // Дополнительный слой отображения: события/комментарии этапов за
        // выбранный день (на цифры зарплаты/КПД не влияет).
        final dayComments = state.dayComments
            .where((c) =>
                c.userId == _employeeId &&
                c.timestamp.day == daySelected &&
                (_workplaceFilter == AnalyticsConstants.allWorkplaces ||
                    c.workplaceId == _workplaceFilter))
            .toList();
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
        final payType = parsePayType(state.employeePayTypes[_employeeId]);
        // В selfView оклад не подставляем даже из PersonnelProvider —
        // финансовые данные не должны участвовать в расчёте на экране.
        final baseDaySalary = widget.permission.canViewFinance
            ? (state.employeeBaseSalaries[_employeeId] ??
                employee.baseDaySalary)
            : 0.0;
        final breakdown = SalaryCalculator.compute(
          events: allEvents,
          coefficients: state.coefficients,
          settings: state.settings,
          adjustments: adj,
          halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
          baseDaySalary: baseDaySalary,
          payType: payType,
          month: state.month,
          statusPeriods: state.employeeStatusHistory[_employeeId] ?? const [],
          statusPayRates: state.statusPayRates,
          statusNames: {for (final s in state.statuses) s.id: s.name},
          setupPrices: widget.service.workplaceSetupPrices,
        );

        final usefulMin = AnalyticsCalculator.usefulMinutes(allEvents);
        final pauseCount = AnalyticsCalculator.countEventsOfType(
            allEvents, AnalyticsEventType.pause);
        final pauseMin = AnalyticsCalculator.pauseMinutes(allEvents);
        final problemCount = AnalyticsCalculator.countEventsOfType(
            allEvents, AnalyticsEventType.problem);
        final problemMin = AnalyticsCalculator.problemMinutes(allEvents);
        final qty = AnalyticsCalculator.totalQty(allEvents);
        // КПД сотрудника по эталону: полезное время / общее время всех
        // событий (см. AnalyticsCalculator.timeKpdPercent).
        final kpdPercent = AnalyticsCalculator.timeKpdPercent(allEvents);

        final mainStack = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnalyticsCard(
              title: 'Рабочие места сотрудника',
              subtitle:
                  'Прокручивайте вбок. Клик по карточке фильтрует timeline и таблицу ниже.',
              child: EmployeeWorkplaceStrip(
                rows: summaries,
                activeFilter: _workplaceFilter,
                onChangeFilter: (id) => setState(() => _workplaceFilter = id),
                onOpenIncidents: (workplaceId, type) => _openIncidents(
                  context: context,
                  workplaceId: workplaceId,
                  type: type,
                  events: allEvents,
                  state: state,
                  personnel: personnel,
                ),
              ),
            ),
            const SizedBox(height: 18),
            AnalyticsCard(
              title: 'Претензии',
              subtitle:
                  'Все претензии сотрудника за месяц: из заказов и из чата '
                  '(чатовые не привязаны к рабочему месту, поэтому в '
                  'карточках выше не учитываются).',
              child: _claimsSummaryRow(state, employee),
            ),
            const SizedBox(height: 18),
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
            const SizedBox(height: 18),
            AnalyticsCard(
              title:
                  'Линия дня: ${daySelected.toString().padLeft(2, '0')}.${state.month.month.toString().padLeft(2, '0')}.${state.month.year}',
              subtitle:
                  'Шкала соответствует заданному графику. Если активность началась раньше или закончилась позже графика — шкала автоматически удлиняется.',
              child: TimelineWidget(
                layout: timeline,
                markers: _commentMarkers(dayComments, daySelected, state),
                workplaceNameOf: (id) =>
                    personnel.workplaceById(id)?.name ?? id,
                employeeNameOf: (id) {
                  try {
                    final e = personnel.employees.firstWhere((x) => x.id == id);
                    return '${e.lastName} ${e.firstName}'.trim();
                  } catch (_) {
                    return id;
                  }
                },
              ),
            ),
            const SizedBox(height: 18),
            AnalyticsCard(
              title: 'Заказы и работы выбранного дня',
              child: DayEventsTable(
                events: dayEvents,
                timeline: timeline,
                workplaceById: {for (final w in personnel.workplaces) w.id: w},
                comments: dayComments,
                employeeNameOf: (id) {
                  try {
                    final e = personnel.employees.firstWhere((x) => x.id == id);
                    return '${e.lastName} ${e.firstName}'.trim();
                  } catch (_) {
                    return id;
                  }
                },
              ),
            ),
          ],
        );

        final sidePanel = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.permission.canViewFinance) ...[
              _salaryCard(breakdown, kpdPercent, baseDaySalary),
              const SizedBox(height: 18),
            ],
            AnalyticsSummaryCard(
              title: 'Общий итог',
              green: true,
              children: [
                AnalyticsStatRow(
                    label: 'Дни / ночи',
                    value: '${breakdown.dayShifts} / ${breakdown.nightShifts}'),
                AnalyticsStatRow(
                    label: 'Полезное время',
                    value: AnalyticsFormat.hoursMinutes(usefulMin)),
                AnalyticsStatRow(
                    label: 'Паузы',
                    value:
                        '$pauseCount · ${AnalyticsFormat.hoursMinutes(pauseMin)}'),
                AnalyticsStatRow(
                    label: 'Проблемы',
                    value:
                        '$problemCount · ${AnalyticsFormat.hoursMinutes(problemMin)}'),
                AnalyticsStatRow(
                    label: 'Сделано', value: AnalyticsFormat.decimal(qty)),
                if (widget.permission.canViewFinance)
                  AnalyticsTotalBox(
                    label: 'К выплате',
                    value: AnalyticsFormat.money(breakdown.total),
                  ),
              ],
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
                _toolbar(context, personnel, employee, allEvents, breakdown),
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

  Widget _toolbar(
      BuildContext context,
      PersonnelProvider personnel,
      EmployeeModel employee,
      List<AnalyticsEvent> events,
      SalaryBreakdown brk) {
    final state = widget.service.state;
    final statusName = state.statuses
        .where((s) => s.id == (state.employeeStatusIds[employee.id] ?? ''))
        .map((s) => s.name)
        .firstWhere((_) => true, orElse: () => '');
    final fullName = '${employee.lastName} ${employee.firstName}'.trim();
    final positionNames = employee.positionIds
        .map((id) => personnel.positionNameById(id))
        .where((s) => s.isNotEmpty)
        .join(', ');

    final left = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.hideBackButton)
          AnalyticsBackLink(
            label: widget.permission.canViewAllEmployees
                ? 'Назад к сотрудникам'
                : 'Назад',
            onTap: () => Navigator.of(context).maybePop(),
          ),
        const SizedBox(height: 6),
        Text(
          fullName.isEmpty ? '—' : fullName,
          style: const TextStyle(
            color: AnalyticsColors.text,
            fontSize: 30,
            fontWeight: FontWeight.w600,
            letterSpacing: -1,
            height: 1.05,
          ),
        ),
        if (positionNames.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            positionNames,
            style: const TextStyle(
              color: AnalyticsColors.muted,
              fontSize: 13,
            ),
          ),
        ],
        if (statusName.isNotEmpty) ...[
          const SizedBox(height: 10),
          _statusBadge(statusName),
        ],
      ],
    );

    final controls = Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        if (widget.permission.canViewAllEmployees)
          AnalyticsFilterGroup(
            label: 'Быстро сменить сотрудника',
            child: AnalyticsInputShell(
              child: DropdownButton<String>(
                value: _employeeId,
                isExpanded: true,
                dropdownColor: AnalyticsColors.card2,
                style: const TextStyle(color: AnalyticsColors.text),
                underline: const SizedBox.shrink(),
                icon:
                    const Icon(Icons.expand_more, color: AnalyticsColors.muted),
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
            ),
          ),
        if (widget.onMonthChanged != null)
          AnalyticsFilterGroup(
            label: 'Месяц',
            child: AnalyticsMonthPicker(
              month: state.month,
              onChanged: (m) {
                // Сбрасываем выбранный день: в другом месяце он может
                // не существовать или не иметь активности.
                setState(() => _selectedDay = null);
                widget.onMonthChanged!(m);
              },
            ),
          ),
        if (widget.permission.canExportPdf)
          AnalyticsPdfButton(
            loading: _pdfLoading,
            onPressed: () => _exportPdf(personnel),
          ),
        if (widget.permission.canExportPdf)
          AnalyticsPdfButton(
            label: 'Ведомость',
            loading: _statementLoading,
            onPressed: () => _exportStatement(personnel),
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

  /// Сводка претензий за месяц: счётчик + кнопка списка (все источники,
  /// включая чатовые без workplaceId — их нет в карточках рабочих мест).
  Widget _claimsSummaryRow(AnalyticsState state, EmployeeModel employee) {
    final claims = state.claims
        .where((c) => c.employeeId == _employeeId)
        .toList(growable: false);
    if (claims.isEmpty) {
      return const Text('Претензий за этот месяц нет',
          style: TextStyle(fontSize: 13, color: AnalyticsColors.muted));
    }
    final month = state.month;
    return Row(
      children: [
        Text(
          'Всего: ${claims.length}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 12),
        TextButton.icon(
          icon: const Icon(Icons.list_alt, size: 18),
          label: const Text('Показать список'),
          onPressed: () => showClaimsListDialog(
            context,
            employeeName: '${employee.lastName} ${employee.firstName}'.trim(),
            monthLabel:
                '${month.month.toString().padLeft(2, '0')}.${month.year}',
            claims: claims,
          ),
        ),
      ],
    );
  }

  Widget _statusBadge(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x4F6A6CF7)),
        color: const Color(0x146A6CF7),
      ),
      child: Text(name,
          style: const TextStyle(
              color: AnalyticsColors.blueDeep,
              fontWeight: FontWeight.w500,
              fontSize: 11)),
    );
  }

  Widget _salaryCard(SalaryBreakdown brk, int kpdPercent, double baseRate) {
    final state = widget.service.state;
    final nightPercent = state.settings.nightPercent;
    final mealAmount = state.settings.mealAmount;
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
          // Тип оплаты и основная начисляемая сумма (как в чипе таблицы).
          _salaryRow(
            brk.isSalaryType ? 'Тип оплаты · Оклад' : 'Тип оплаты · Сдельно',
            AnalyticsFormat.money(brk.primaryEarned),
          ),
          // Редактирование ставки оклада за смену (гейт canEdit).
          _adjustmentField('Ставка оклада (за смену)', baseRate, (v) async {
            try {
              await widget.service
                  .setEmployeeBaseSalary(employeeId: _employeeId, value: v);
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Не удалось сохранить ставку: $e')),
              );
            }
          }),
          const Divider(color: AnalyticsColors.line),
          _salaryRow('Сдельно', AnalyticsFormat.money(brk.pieceSalary)),
          _salaryRow(
              'Оклад за смены', AnalyticsFormat.money(brk.baseSalaryPay)),
          for (final line in brk.statusPayBreakdown)
            _salaryRow(
              'По статусу «${line.statusName}»: ${line.shifts} смен × ${AnalyticsFormat.money(line.rate)}',
              AnalyticsFormat.money(line.amount),
            ),
          _salaryRow('Средняя сдельная',
              AnalyticsFormat.money(brk.averageShiftSalary)),
          _salaryRow(
              'Ночные ${brk.nightShifts} × ${nightPercent.toStringAsFixed(0)}%',
              AnalyticsFormat.money(brk.nightBonus)),
          // Питание за счёт компании: показываем расход, но без минуса — из
          // зарплаты оно не удерживается.
          _salaryRow(
              'Питание ${brk.shiftsTotal} порц. × ${AnalyticsFormat.money(mealAmount)} (за счёт компании)',
              AnalyticsFormat.money(brk.mealDeduction)),
          _salaryRow('Начислено', AnalyticsFormat.money(brk.accrued)),
          _salaryRow('КПД', '$kpdPercent%'),
          const Divider(color: AnalyticsColors.line),
          _adjustmentField('Компенсация', adj.compensation, (v) {
            widget.service.saveSalaryAdjustments(adj.copyWith(compensation: v));
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
            widget.service.saveSalaryAdjustments(adj.copyWith(discipline: v));
          }),
          _adjustmentField('Браки', adj.defect, (v) {
            widget.service.saveSalaryAdjustments(adj.copyWith(defect: v));
          }),
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
                    color: AnalyticsColors.text, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _adjustmentField(
      String label, double value, ValueChanged<double> onChanged) {
    final ctrl = TextEditingController(
        text: AnalyticsFormat.decimal(value, precision: 0));
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
                  color: AnalyticsColors.text, fontWeight: FontWeight.w500),
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
