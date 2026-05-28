import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../personnel/employee_model.dart';
import '../../personnel/personnel_provider.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/salary_calculator.dart';
import '../models/analytics_event.dart';
import '../models/employee_status.dart';
import '../models/pay_type.dart';
import '../models/salary_adjustments.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';

class EmployeesTable extends StatelessWidget {
  const EmployeesTable({
    super.key,
    required this.service,
    required this.personnel,
    required this.canViewFinance,
    required this.onEmployeeTap,
  });

  final AnalyticsService service;
  final PersonnelProvider personnel;
  final bool canViewFinance;
  final ValueChanged<String> onEmployeeTap;

  @override
  Widget build(BuildContext context) {
    final state = service.state;
    final events = state.events;
    final eventsByEmployee = <String, List<AnalyticsEvent>>{};
    for (final e in events) {
      eventsByEmployee.putIfAbsent(e.employeeId, () => []).add(e);
    }

    final claimsByEmployee = <String, int>{};
    for (final c in state.claims) {
      claimsByEmployee[c.employeeId] = (claimsByEmployee[c.employeeId] ?? 0) + 1;
    }

    final statusById = <String, EmployeeStatus>{
      for (final s in state.statuses) s.id: s,
    };

    final activeEmployees =
        personnel.employees.where((e) => !e.isFired).toList()
          ..sort((a, b) => ('${a.lastName} ${a.firstName}')
              .compareTo('${b.lastName} ${b.firstName}'));

    final rows = activeEmployees.map((emp) {
      final list = eventsByEmployee[emp.id] ?? const <AnalyticsEvent>[];
      final adj = state.adjustments[emp.id] ??
          SalaryAdjustments.zero(emp.id, state.month.firstDay);
      final breakdown = SalaryCalculator.compute(
        events: list,
        coefficients: state.coefficients,
        settings: state.settings,
        adjustments: adj,
        halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      );
      final statusName = statusById[state.employeeStatusIds[emp.id] ?? '']?.name;
      final payTypeRaw = state.employeePayTypes[emp.id];
      final payType = parsePayType(payTypeRaw);
      return _Row(
        employee: emp,
        events: list,
        statusName: statusName,
        payType: payType,
        breakdown: breakdown,
        claims: claimsByEmployee[emp.id] ?? 0,
      );
    }).toList();

    final columns = <_Col>[
      _Col('Сотрудник', sticky: true),
      const _Col('Дни'),
      const _Col('Ночи'),
      const _Col('Рабочие места', flex: 2),
      const _Col('Сделано'),
      const _Col('Приладка'),
      const _Col('Паузы'),
      const _Col('Проблемы'),
      const _Col('Претензии'),
      if (canViewFinance) const _Col('Тип оплаты'),
      if (canViewFinance) const _Col('Средняя ЗП'),
      if (canViewFinance) const _Col('Ночные'),
      if (canViewFinance) const _Col('Компенсации'),
      if (canViewFinance) const _Col('Соц. отчисл.'),
      if (canViewFinance) const _Col('Питание'),
      if (canViewFinance) const _Col('Аванс'),
      if (canViewFinance) const _Col('ЗП безнал'),
      if (canViewFinance) const _Col('Дисциплина'),
      if (canViewFinance) const _Col('Браки'),
      if (canViewFinance) const _Col('Итог ЗП'),
      if (canViewFinance) const _Col('Ведомость'),
    ];

    final minWidth = canViewFinance ? 2480.0 : 1500.0;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite
          ? math.max(constraints.maxWidth, minWidth)
          : minWidth;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _headerRow(columns),
              ...rows.map((r) => _dataRow(context, r, canViewFinance)),
              _footer(rows, canViewFinance),
            ],
          ),
        ),
      );
    });
  }

  Widget _headerRow(List<_Col> columns) {
    return Container(
      decoration: const BoxDecoration(color: Color(0xFF121A2E)),
      child: Row(
        children: columns.map((c) {
          return Expanded(
            flex: c.flex,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(
                c.label.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFFCBD5E1),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _dataRow(BuildContext context, _Row r, bool finance) {
    final pauseMin = AnalyticsCalculator.pauseMinutes(r.events);
    final problemMin = AnalyticsCalculator.problemMinutes(r.events);
    final qty = AnalyticsCalculator.totalQty(r.events);
    final setupQty = AnalyticsCalculator.totalSetupQty(r.events);
    final pauseCount =
        AnalyticsCalculator.countEventsOfType(r.events, AnalyticsEventType.pause);
    final problemCount = AnalyticsCalculator.countEventsOfType(
        r.events, AnalyticsEventType.problem);

    // Группировка по workplace
    final byWp = <String, List<AnalyticsEvent>>{};
    for (final e in r.events) {
      byWp.putIfAbsent(e.workplaceId, () => []).add(e);
    }
    final wpRows = byWp.entries.map((entry) {
      final wp = personnel.workplaceById(entry.key);
      final useful = AnalyticsCalculator.usefulMinutes(entry.value);
      final q = AnalyticsCalculator.totalQty(entry.value);
      final speed = useful > 0 ? q / useful : 0.0;
      final unit = wp?.unit?.trim().isNotEmpty == true ? wp!.unit!.trim() : 'ед.';
      return '${wp?.name ?? entry.key}: '
          '${AnalyticsFormat.decimal(q)} $unit · '
          '${AnalyticsFormat.hoursMinutes(useful)} · '
          '${AnalyticsFormat.decimal(speed)} $unit/мин';
    }).toList();

    return InkWell(
      onTap: () => onEmployeeTap(r.employee.id),
      child: Container(
        decoration: BoxDecoration(
          color: AnalyticsColors.card2.withOpacity(0.6),
          border: Border(bottom: BorderSide(color: AnalyticsColors.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cell(
              flex: 1,
              child: _EmployeeCell(employee: r.employee, status: r.statusName),
            ),
            _cell(child: Text('${r.breakdown.dayShifts}', style: _cellStyle())),
            _cell(child: Text('${r.breakdown.nightShifts}', style: _cellStyle())),
            _cell(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: wpRows.isEmpty
                    ? [Text('—', style: _mutedStyle())]
                    : wpRows
                        .map((s) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: Text(s,
                                  style: _cellStyle().copyWith(
                                      fontSize: 11)),
                            ))
                        .toList(),
              ),
            ),
            _cell(
                child: Text(
              '${AnalyticsFormat.decimal(qty)}',
              style: _cellStyle(),
            )),
            _cell(
                child: Text(
              '${AnalyticsFormat.decimal(setupQty)}',
              style: _cellStyle(),
            )),
            _cell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$pauseCount', style: _cellStyle()),
                  Text(AnalyticsFormat.hoursMinutes(pauseMin),
                      style: _mutedStyle()),
                ],
              ),
            ),
            _cell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$problemCount', style: _cellStyle()),
                  Text(AnalyticsFormat.hoursMinutes(problemMin),
                      style: _mutedStyle()),
                ],
              ),
            ),
            _cell(child: Text('${r.claims}', style: _cellStyle())),
            if (finance)
              _cell(child: Text(_payTypeText(r), style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.averageShiftSalary),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.nightBonus),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.compensation),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.social),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AnalyticsFormat.money(r.breakdown.mealDeduction),
                          style: _cellStyle()),
                      Text(
                        '${r.breakdown.shiftsTotal} порц.',
                        style: _mutedStyle(),
                      ),
                    ],
                  )),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.advance),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.cashless),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.discipline),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.defect),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.total),
                      style: _cellStyle()
                          .copyWith(fontWeight: FontWeight.w900))),
            if (finance)
              _cell(
                  child: TextButton(
                onPressed: () => onEmployeeTap(r.employee.id),
                child: const Text(
                  'Открыть',
                  style: TextStyle(color: AnalyticsColors.blue),
                ),
              )),
          ],
        ),
      ),
    );
  }

  Widget _footer(List<_Row> rows, bool finance) {
    int shifts = 0;
    int days = 0;
    int nights = 0;
    double qtyAll = 0;
    int pauseCount = 0;
    int pauseM = 0;
    int problemCount = 0;
    int problemM = 0;
    double salarySum = 0;
    int usefulM = 0;
    for (final r in rows) {
      shifts += r.breakdown.shiftsTotal;
      days += r.breakdown.dayShifts;
      nights += r.breakdown.nightShifts;
      qtyAll += AnalyticsCalculator.totalQty(r.events);
      usefulM += AnalyticsCalculator.usefulMinutes(r.events);
      pauseCount += AnalyticsCalculator.countEventsOfType(
          r.events, AnalyticsEventType.pause);
      pauseM += AnalyticsCalculator.pauseMinutes(r.events);
      problemCount += AnalyticsCalculator.countEventsOfType(
          r.events, AnalyticsEventType.problem);
      problemM += AnalyticsCalculator.problemMinutes(r.events);
      salarySum += r.breakdown.total;
    }

    Widget c(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: const TextStyle(
                      color: AnalyticsColors.text,
                      fontWeight: FontWeight.w900,
                      fontSize: 12)),
              Text(label,
                  style: const TextStyle(
                      color: AnalyticsColors.muted, fontSize: 10)),
            ],
          ),
        );

    return Container(
      decoration: BoxDecoration(
        color: AnalyticsColors.card.withOpacity(0.95),
        border: Border(
            top: BorderSide(
                color: AnalyticsColors.green.withOpacity(0.4), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(child: c('всего смен', '$shifts')),
          Expanded(child: c('дней', '$days')),
          Expanded(child: c('ночей', '$nights')),
          Expanded(
              flex: 2,
              child: c('сделано',
                  '${AnalyticsFormat.decimal(qtyAll)} (полезное ${AnalyticsFormat.hoursMinutes(usefulM)})')),
          Expanded(child: c('сделано', AnalyticsFormat.decimal(qtyAll))),
          Expanded(child: c('наладка', '—')),
          Expanded(
              child: c('паузы',
                  '$pauseCount · ${AnalyticsFormat.hoursMinutes(pauseM)}')),
          Expanded(
              child: c('проблемы',
                  '$problemCount · ${AnalyticsFormat.hoursMinutes(problemM)}')),
          Expanded(child: c('претензии', '—')),
          if (finance)
            for (var i = 0; i < 11; i++) Expanded(child: c('—', '—')),
          if (finance)
            Expanded(child: c('итог ЗП', AnalyticsFormat.money(salarySum))),
          if (finance) const Expanded(child: SizedBox.shrink()),
        ],
      ),
    );
  }

  Widget _cell({required Widget child, int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: child,
      ),
    );
  }

  TextStyle _cellStyle() => const TextStyle(
        color: AnalyticsColors.text,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      );

  TextStyle _mutedStyle() =>
      const TextStyle(color: AnalyticsColors.muted, fontSize: 11);

  String _payTypeText(_Row r) {
    if (r.payType == null) return '—';
    final amount = r.payType == PayType.salary
        ? r.breakdown.averageShiftSalary * r.breakdown.shiftsTotal
        : r.breakdown.pieceSalary;
    return '${payTypeLabel(r.payType!)}: ${AnalyticsFormat.money(amount)}';
  }
}

class _Row {
  final EmployeeModel employee;
  final List<AnalyticsEvent> events;
  final String? statusName;
  final PayType? payType;
  final SalaryBreakdown breakdown;
  final int claims;

  const _Row({
    required this.employee,
    required this.events,
    required this.statusName,
    required this.payType,
    required this.breakdown,
    required this.claims,
  });
}

class _Col {
  final String label;
  final int flex;
  final bool sticky;
  const _Col(this.label, {this.flex = 1, this.sticky = false});
}

class _EmployeeCell extends StatelessWidget {
  const _EmployeeCell({required this.employee, required this.status});
  final EmployeeModel employee;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final full = '${employee.lastName} ${employee.firstName}'.trim();
    final initials = (employee.lastName.isNotEmpty
            ? employee.lastName[0]
            : (employee.firstName.isNotEmpty ? employee.firstName[0] : '?'))
        .toUpperCase();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: AnalyticsColors.accentGradient,
          ),
          alignment: Alignment.center,
          child: Text(
            initials,
            style: const TextStyle(
              color: Color(0xFF00121C),
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                full.isEmpty ? '—' : full,
                style: const TextStyle(
                  color: AnalyticsColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (status != null && status!.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: const Color(0x4F38BDF8)),
                    borderRadius: BorderRadius.circular(999),
                    color: const Color(0x261A8FB5),
                  ),
                  child: Text(
                    status!,
                    style: const TextStyle(
                      color: Color(0xFF7DD3FC),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
