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
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';
import '../utils/h_scroll_sync.dart';
import 'analytics_table_parts.dart';

class EmployeesTable extends StatefulWidget {
  const EmployeesTable({
    super.key,
    required this.service,
    required this.personnel,
    required this.permission,
    required this.onEmployeeTap,
  });

  final AnalyticsService service;
  final PersonnelProvider personnel;
  final AnalyticsPermissionService permission;
  final ValueChanged<String> onEmployeeTap;

  @override
  State<EmployeesTable> createState() => _EmployeesTableState();
}

class _EmployeesTableState extends State<EmployeesTable> {
  // Linked horizontal-scroll sync — header and footer only (2 controllers).
  // Body rows use ValueListenableBuilder + Transform.translate to avoid
  // creating a ScrollController per row (which caused 50+ jumpTo() calls
  // per scroll event and severe frame-rate drops).
  final HScrollSync _sync = HScrollSync();
  final Map<int, ScrollController> _ctrlCache = {};

  // Row computation cache — avoids running SalaryCalculator on every repaint.
  AnalyticsState? _lastState;
  List<_Row> _rows = const [];

  // Only header (-1) and footer (10000) get real scroll controllers.
  ScrollController _ctrl(int key) =>
      _ctrlCache.putIfAbsent(key, () => _sync.acquire());

  void _maybeRecompute(AnalyticsState state) {
    if (state.loading) return;
    if (identical(state, _lastState)) return;
    _lastState = state;
    _rows = _buildRows(state);
  }

  List<_Row> _buildRows(AnalyticsState state) {
    final eventsByEmployee = <String, List<AnalyticsEvent>>{};
    for (final e in state.events) {
      eventsByEmployee.putIfAbsent(e.employeeId, () => []).add(e);
    }
    final claimsByEmployee = <String, int>{};
    for (final c in state.claims) {
      claimsByEmployee[c.employeeId] =
          (claimsByEmployee[c.employeeId] ?? 0) + 1;
    }
    final statusById = <String, EmployeeStatus>{
      for (final s in state.statuses) s.id: s,
    };

    final activeEmployees = widget.personnel.employees
        .where((e) => !e.isFired && widget.permission.canViewEmployee(e.id))
        .toList()
          ..sort((a, b) => ('${a.lastName} ${a.firstName}')
              .compareTo('${b.lastName} ${b.firstName}'));

    return activeEmployees.map((emp) {
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
      final statusName =
          statusById[state.employeeStatusIds[emp.id] ?? '']?.name;
      final payType = parsePayType(state.employeePayTypes[emp.id]);
      return _Row(
        employee: emp,
        events: list,
        statusName: statusName,
        payType: payType,
        breakdown: breakdown,
        claims: claimsByEmployee[emp.id] ?? 0,
      );
    }).toList();
  }

  @override
  void dispose() {
    _sync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state;
    _maybeRecompute(state);

    final canViewFinance = widget.permission.canViewFinance;
    final rows = _rows;

    // Sticky column: 300 px (как .sticky-employee-column в эталоне).
    // Rest: min 1300 (no finance) or 2280 (finance).
    const stickyWidth = 300.0;
    final restMinWidth = canViewFinance ? 2280.0 : 1300.0;

    return LayoutBuilder(builder: (context, constraints) {
      final restWidth = constraints.maxWidth.isFinite
          ? math.max(constraints.maxWidth - stickyWidth, restMinWidth)
          : restMinWidth;

      Widget stickyCell(Widget child,
          {Color? bg, Gradient? gradient, BoxBorder? border, EdgeInsets? padding}) {
        return Container(
          width: stickyWidth,
          decoration: BoxDecoration(color: bg, gradient: gradient, border: border),
          padding: padding ??
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: child,
        );
      }

      // ── Header ──────────────────────────────────────────────────────────
      final headerSticky = stickyCell(
        Text(
          'СОТРУДНИК',
          style: const TextStyle(
            color: AnalyticsColors.tableHeaderText,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        gradient: AnalyticsColors.tableStickyHeaderGradient,
      );

      // ── Footer aggregates ────────────────────────────────────────────────
      int shifts = 0, days = 0, nights = 0;
      double qtyAll = 0;
      int pauseCount = 0, pauseM = 0, problemCount = 0, problemM = 0;
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

      final footerSticky = stickyCell(
        _footerCell('всего смен', '$shifts'),
        gradient: AnalyticsColors.tableFooterStickyGradient,
        border: Border(
            top: BorderSide(
                color: AnalyticsColors.green.withOpacity(0.24), width: 1)),
        padding: EdgeInsets.zero,
      );

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header row ─────────────────────────────────────────────────
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                headerSticky,
                Expanded(
                  child: StickyScrollArea(
                    child: SingleChildScrollView(
                      // key -1 reserved for header
                      controller: _ctrl(-1),
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: SizedBox(
                        width: restWidth,
                        child:
                            _buildScrollableHeader(canViewFinance, restWidth),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Data rows ──────────────────────────────────────────────────
          // ONE ValueListenableBuilder drives all rows via Transform.translate.
          // This replaces the previous per-row ScrollController (N controllers
          // + N jumpTo() calls per scroll event → severe lag with 30+ rows).
          // Hover is local to each _HoverableRow → only the hovered row
          // repaints, the synced scroll path is untouched.
          ValueListenableBuilder<double>(
            valueListenable: _sync.offsetNotifier,
            builder: (context, hOffset, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < rows.length; i++)
                    HoverableRow(
                      builder: (hovered) => IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildStickyDataCell(
                                rows[i], stickyWidth, hovered),
                            Expanded(
                              child: StickyScrollArea(
                                child: ClipRect(
                                  child: Transform.translate(
                                    offset: Offset(-hOffset, 0),
                                    child: SizedBox(
                                      width: restWidth,
                                      child: _buildScrollableDataRow(context,
                                          rows[i], canViewFinance, i, hovered),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          // ── Footer row ─────────────────────────────────────────────────
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                footerSticky,
                Expanded(
                  child: StickyScrollArea(
                    child: SingleChildScrollView(
                      // key 10000 reserved for footer
                      controller: _ctrl(10000),
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: SizedBox(
                        width: restWidth,
                        child: _buildScrollableFooter(
                            canViewFinance, restWidth, days, nights,
                            qtyAll, usefulM, pauseCount, pauseM,
                            problemCount, problemM, salarySum),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget _buildScrollableHeader(bool finance, double width) {
    final cols = <String>[
      'Дни',
      'Ночи',
      'Рабочие места',
      'Сделано',
      'Приладка',
      'Паузы',
      'Проблемы',
      'Претензии',
      if (finance) 'Тип оплаты',
      if (finance) 'Средняя ЗП',
      if (finance) 'Ночные',
      if (finance) 'Компенсации',
      if (finance) 'Соц. отчисл.',
      if (finance) 'Питание',
      if (finance) 'Аванс',
      if (finance) 'ЗП безнал',
      if (finance) 'Дисциплина',
      if (finance) 'Браки',
      if (finance) 'Итог ЗП',
      if (finance) 'Ведомость',
    ];
    return Container(
      decoration: const BoxDecoration(gradient: AnalyticsColors.tableHeaderGradient),
      child: Row(
        children: cols.map((label) {
          final flex = label == 'Рабочие места' ? 2 : 1;
          return Expanded(
            flex: flex,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: AnalyticsColors.tableHeaderText,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStickyDataCell(_Row r, double width, bool hovered) {
    return InkWell(
      onTap: widget.permission.canViewEmployee(r.employee.id)
          ? () => widget.onEmployeeTap(r.employee.id)
          : null,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          gradient: hovered
              ? AnalyticsColors.tableStickyHoverGradient
              : AnalyticsColors.tableStickyColumnGradient,
          border: const Border(
              bottom: BorderSide(color: AnalyticsColors.line)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: _EmployeeCell(employee: r.employee, status: r.statusName),
      ),
    );
  }

  Widget _buildScrollableDataRow(
      BuildContext context, _Row r, bool finance, int index, bool hovered) {
    final pauseMin = AnalyticsCalculator.pauseMinutes(r.events);
    final problemMin = AnalyticsCalculator.problemMinutes(r.events);
    final qty = AnalyticsCalculator.totalQty(r.events);
    final setupQty = AnalyticsCalculator.totalSetupQty(r.events);
    final pauseCount = AnalyticsCalculator.countEventsOfType(
        r.events, AnalyticsEventType.pause);
    final problemCount = AnalyticsCalculator.countEventsOfType(
        r.events, AnalyticsEventType.problem);

    final byWp = <String, List<AnalyticsEvent>>{};
    for (final e in r.events) {
      byWp.putIfAbsent(e.workplaceId, () => []).add(e);
    }
    final wpRows = byWp.entries.map((entry) {
      final wp = widget.personnel.workplaceById(entry.key);
      final useful = AnalyticsCalculator.usefulMinutes(entry.value);
      final q = AnalyticsCalculator.totalQty(entry.value);
      final speed = useful > 0 ? q / useful : 0.0;
      final unit =
          wp?.unit?.trim().isNotEmpty == true ? wp!.unit!.trim() : 'ед.';
      return '${wp?.name ?? entry.key}: '
          '${AnalyticsFormat.decimal(q)} $unit · '
          '${AnalyticsFormat.hoursMinutes(useful)} · '
          '${AnalyticsFormat.decimal(speed)} $unit/мин';
    }).toList();

    final rowColor = hovered
        ? AnalyticsColors.rowHover
        : (index.isEven ? AnalyticsColors.zebraOdd : AnalyticsColors.zebraEven);
    return InkWell(
      onTap: widget.permission.canViewEmployee(r.employee.id)
          ? () => widget.onEmployeeTap(r.employee.id)
          : null,
      child: Container(
        decoration: BoxDecoration(
          color: rowColor,
          border: const Border(
              bottom: BorderSide(color: AnalyticsColors.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cell(child: Text('${r.breakdown.dayShifts}', style: _cellStyle())),
            _cell(
                child:
                    Text('${r.breakdown.nightShifts}', style: _cellStyle())),
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
                                  style:
                                      _cellStyle().copyWith(fontSize: 11)),
                            ))
                        .toList(),
              ),
            ),
            _cell(
                child: Text('${AnalyticsFormat.decimal(qty)}',
                    style: _cellStyle())),
            _cell(
                child: Text('${AnalyticsFormat.decimal(setupQty)}',
                    style: _cellStyle())),
            _cell(
              child: _twoLine(
                Text('$pauseCount', style: _cellStyle()),
                Text(AnalyticsFormat.hoursMinutes(pauseMin),
                    style: _mutedStyle()),
              ),
            ),
            _cell(
              child: _twoLine(
                Text('$problemCount', style: _cellStyle()),
                Text(AnalyticsFormat.hoursMinutes(problemMin),
                    style: _mutedStyle()),
              ),
            ),
            _cell(child: Text('${r.claims}', style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(_payTypeText(r), style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(
                      AnalyticsFormat.money(r.breakdown.averageShiftSalary),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(
                      AnalyticsFormat.money(r.breakdown.nightBonus),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(
                      AnalyticsFormat.money(r.breakdown.compensation),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.social),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: _twoLine(
                Text(AnalyticsFormat.money(r.breakdown.mealDeduction),
                    style: _cellStyle()),
                Text(
                  '${r.breakdown.shiftsTotal} порц.',
                  style: _mutedStyle(),
                ),
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
                  child: Text(
                      AnalyticsFormat.money(r.breakdown.discipline),
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
                onPressed: () => widget.onEmployeeTap(r.employee.id),
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

  Widget _buildScrollableFooter(
    bool finance,
    double width,
    int days,
    int nights,
    double qtyAll,
    int usefulM,
    int pauseCount,
    int pauseM,
    int problemCount,
    int problemM,
    double salarySum,
  ) {
    Widget c(String label, String value) => _footerCell(label, value);

    return Container(
      decoration: BoxDecoration(
        color: AnalyticsColors.footerBg,
        border: Border(
            top: BorderSide(
                color: AnalyticsColors.green.withOpacity(0.24), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(child: c('дней', '$days')),
          Expanded(child: c('ночей', '$nights')),
          Expanded(
              flex: 2,
              child: c('сделано',
                  '${AnalyticsFormat.decimal(qtyAll)} (${AnalyticsFormat.hoursMinutes(usefulM)})')),
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

  static Widget _footerCell(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: _twoLine(
          Text(value,
              style: const TextStyle(
                  color: AnalyticsColors.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 12)),
          Text(label,
              style: const TextStyle(
                  color: AnalyticsColors.muted, fontSize: 10)),
        ),
      );

  /// Двухстрочная ячейка (значение + подпись). FittedBox мягко ужимает
  /// содержимое, когда высота строки меньше суммы двух строк текста
  /// (например, при увеличенном системном масштабе текста) — вместо
  /// RenderFlex overflow.
  static Widget _twoLine(Widget top, Widget bottom) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [top, bottom],
        ),
      );

  Widget _cell({required Widget child, int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: AnalyticsColors.avatarGradient,
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
                    border:
                        Border.all(color: const Color(0x4F38BDF8)),
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
