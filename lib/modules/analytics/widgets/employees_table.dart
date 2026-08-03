import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../personnel/employee_model.dart';
import '../../personnel/employee_status_model.dart';
import '../../personnel/personnel_provider.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/salary_calculator.dart';
import '../models/analytics_event.dart';
import '../models/pay_type.dart';
import '../models/salary_adjustments.dart';
import '../services/analytics_pdf_export_service.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';
import '../utils/h_scroll_sync.dart';
import 'analytics_table_parts.dart';
import 'claims_list_dialog.dart';

class EmployeesTable extends StatefulWidget {
  const EmployeesTable({
    super.key,
    required this.service,
    required this.personnel,
    required this.permission,
    required this.onEmployeeTap,
    this.verticalController,
  });

  final AnalyticsService service;
  final PersonnelProvider personnel;
  final AnalyticsPermissionService permission;
  final ValueChanged<String> onEmployeeTap;

  /// Контроллер внутреннего вертикального скролла строк (для Scrollbar
  /// снаружи). Используется только при ограниченной высоте — когда таблица
  /// сама прокручивает строки под закреплённой шапкой. Если null — таблица
  /// создаёт собственный контроллер.
  final ScrollController? verticalController;

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

  // Собственный вертикальный контроллер — только если снаружи не передан
  // widget.verticalController (создаётся лениво, утилизируется в dispose).
  ScrollController? _ownedVerticalCtrl;

  ScrollController get _verticalCtrl =>
      widget.verticalController ?? (_ownedVerticalCtrl ??= ScrollController());

  // Row computation cache — avoids running SalaryCalculator on every repaint.
  AnalyticsState? _lastState;
  List<_Row> _rows = const [];

  // Экспорт ведомости из колонки «Ведомость»: id сотрудника, для которого
  // идёт генерация (кнопки остальных строк остаются активными, повторный
  // клик по той же строке игнорируется).
  final _pdfService = AnalyticsPdfExportService();
  String? _statementExportingFor;

  // Only header (-1) and footer (10000) get real scroll controllers.
  ScrollController _ctrl(int key) =>
      _ctrlCache.putIfAbsent(key, () => _sync.acquire());

  /// Горизонтальный drag над строками данных. Строки — пассивные
  /// Transform.translate без собственных Scrollable, поэтому жест двигает
  /// контроллер header'а, а HScrollSync сам разносит offset по
  /// header/footer/строкам. Тапы по строкам и вертикальный скролл не
  /// перехватываются: жест-арена отдаёт тап InkWell'у строки, а вертикальный
  /// drag — внешнему вертикальному Scrollable.
  void _onRowsHorizontalDrag(DragUpdateDetails details) {
    final ctrl = _ctrl(-1);
    if (!ctrl.hasClients) return;
    final target = (ctrl.offset - details.delta.dx)
        .clamp(0.0, ctrl.position.maxScrollExtent);
    if (target != ctrl.offset) ctrl.jumpTo(target);
  }

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
    // Цены за приладку (workplaces.priladka_price, только места с приладкой).
    final setupPrices = widget.service.workplaceSetupPrices;

    final activeEmployees = widget.personnel.employees
        .where((e) => !e.isFired && widget.permission.canViewEmployee(e.id))
        .toList()
          ..sort((a, b) => ('${a.lastName} ${a.firstName}')
              .compareTo('${b.lastName} ${b.firstName}'));

    return activeEmployees.map((emp) {
      final list = eventsByEmployee[emp.id] ?? const <AnalyticsEvent>[];
      final adj = state.adjustments[emp.id] ??
          SalaryAdjustments.zero(emp.id, state.month.firstDay);
      final payType = parsePayType(state.employeePayTypes[emp.id]);
      final baseDaySalary =
          state.employeeBaseSalaries[emp.id] ?? emp.baseDaySalary;
      final breakdown = SalaryCalculator.compute(
        events: list,
        coefficients: state.coefficients,
        settings: state.settings,
        adjustments: adj,
        halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
        baseDaySalary: baseDaySalary,
        payType: payType,
        month: state.month,
        statusPeriods: state.employeeStatusHistory[emp.id] ?? const [],
        statusPayRates: state.statusPayRates,
        statusNames: {for (final s in state.statuses) s.id: s.name},
        setupPrices: setupPrices,
      );
      final statusName =
          statusById[state.employeeStatusIds[emp.id] ?? '']?.name;
      final positionNames = emp.positionIds
          .map((id) => widget.personnel.positionNameById(id))
          .where((s) => s.isNotEmpty)
          .join(', ');

      // Агрегаты строки считаем один раз здесь, а не в build ячеек:
      // раньше AnalyticsCalculator гонялся по событиям каждой строки при
      // каждой её пересборке (hover, скролл) — O(events)×строки×тик.
      final byWp = <String, List<AnalyticsEvent>>{};
      for (final e in list) {
        byWp.putIfAbsent(e.workplaceId, () => []).add(e);
      }
      final workplaceStats = byWp.entries.map((entry) {
        final wp = widget.personnel.workplaceById(entry.key);
        return _WorkplaceStat(
          name: wp?.name ?? entry.key,
          unit: wp?.unit?.trim().isNotEmpty == true ? wp!.unit!.trim() : 'ед.',
          // «Общее время» — всё время на рабочем месте (работа, наладка,
          // паузы, проблемы), а не только производственное.
          totalMinutes: AnalyticsCalculator.totalMinutes(entry.value),
          productionMinutes: AnalyticsCalculator.usefulMinutes(entry.value),
          setupMinutes: AnalyticsCalculator.setupMinutes(entry.value),
          qty: AnalyticsCalculator.totalQty(entry.value),
          setupQty: AnalyticsCalculator.totalSetupQty(entry.value),
        );
      }).toList();

      return _Row(
        employee: emp,
        events: list,
        statusName: statusName,
        positionNames: positionNames,
        payType: payType,
        breakdown: breakdown,
        claims: claimsByEmployee[emp.id] ?? 0,
        pauseCount: AnalyticsCalculator.countEventsOfType(
            list, AnalyticsEventType.pause),
        pauseMinutes: AnalyticsCalculator.pauseMinutes(list),
        problemCount: AnalyticsCalculator.countEventsOfType(
            list, AnalyticsEventType.problem),
        problemMinutes: AnalyticsCalculator.problemMinutes(list),
        setupQty: AnalyticsCalculator.totalSetupQty(list),
        workplaceStats: workplaceStats,
      );
    }).toList();
  }

  @override
  void didUpdateWidget(covariant EmployeesTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Кэш _rows ключуется по identity AnalyticsState (сервис пересоздаёт
    // state на каждую загрузку — realtime-обновления инвалидируют кэш сами).
    // Если сменился сам сервис/провайдер персонала — сбрасываем явно.
    if (!identical(oldWidget.service, widget.service) ||
        !identical(oldWidget.personnel, widget.personnel)) {
      _lastState = null;
    }
  }

  @override
  void dispose() {
    _ownedVerticalCtrl?.dispose();
    _sync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state;
    _maybeRecompute(state);

    final canViewFinance = widget.permission.canViewFinance;
    final canEdit = widget.permission.canEdit;
    final rows = _rows;
    final nightPercent = state.settings.nightPercent;
    final mealAmount = state.settings.mealAmount;

    // Sticky column: 300 px (как .sticky-employee-column в эталоне).
    // Rest пересчитан под текущее число колонок (агрегированная «Сделано»
    // убрана — количество по каждому месту в своей единице выводится
    // в «Рабочие места»; вместо «Приладки» — «Средняя скорость», тоже
    // двойной ширины): 8 нефинансовых (flex 10, две колонки по 2) +
    // 13 финансовых = 21 колонка (flex 23); ширина на flex прежняя
    // (~120/145 px).
    const stickyWidth = 300.0;
    final restMinWidth = canViewFinance ? 2760.0 : 1450.0;

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
      double setupAll = 0;
      int pauseCount = 0, pauseM = 0, problemCount = 0, problemM = 0;
      int claimsAll = 0;
      double salarySum = 0;
      double pieceSum = 0, earnedSum = 0, nightSum = 0, compSum = 0, socialSum = 0;
      double mealSum = 0, advSum = 0, cashSum = 0, discSum = 0, defSum = 0;
      double setupPaySum = 0;
      int usefulM = 0;
      for (final r in rows) {
        shifts += r.breakdown.shiftsTotal;
        days += r.breakdown.dayShifts;
        nights += r.breakdown.nightShifts;
        setupAll += r.setupQty;
        usefulM += AnalyticsCalculator.usefulMinutes(r.events);
        pauseCount += r.pauseCount;
        pauseM += r.pauseMinutes;
        problemCount += r.problemCount;
        problemM += r.problemMinutes;
        claimsAll += r.claims;
        pieceSum += r.breakdown.pieceSalary;
        earnedSum += r.breakdown.primaryEarned;
        setupPaySum += r.breakdown.setupPay;
        nightSum += r.breakdown.nightBonus;
        compSum += r.breakdown.compensation;
        socialSum += r.breakdown.social;
        mealSum += r.breakdown.mealDeduction;
        advSum += r.breakdown.advance;
        cashSum += r.breakdown.cashless;
        discSum += r.breakdown.discipline;
        defSum += r.breakdown.defect;
        salarySum += r.breakdown.total;
      }
      final totals = _FooterTotals(
        shifts: shifts,
        days: days,
        nights: nights,
        setupAll: setupAll,
        usefulM: usefulM,
        pauseCount: pauseCount,
        pauseM: pauseM,
        problemCount: problemCount,
        problemM: problemM,
        claimsAll: claimsAll,
        pieceSum: pieceSum,
        earnedSum: earnedSum,
        avgPiece: shifts > 0 ? pieceSum / shifts : 0.0,
        nightSum: nightSum,
        compSum: compSum,
        socialSum: socialSum,
        mealSum: mealSum,
        advSum: advSum,
        cashSum: cashSum,
        discSum: discSum,
        defSum: defSum,
        salarySum: salarySum,
        setupPaySum: setupPaySum,
      );

      final footerSticky = stickyCell(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Text(
            'Общий итог',
            style: TextStyle(
                color: AnalyticsColors.text,
                fontWeight: FontWeight.w900,
                fontSize: 12),
          ),
        ),
        gradient: AnalyticsColors.tableFooterStickyGradient,
        border: Border(
            top: BorderSide(
                color: AnalyticsColors.green.withOpacity(0.24), width: 1)),
        padding: EdgeInsets.zero,
      );

      // ── Header row ───────────────────────────────────────────────────
      final headerRow = IntrinsicHeight(
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
                  child: IntrinsicHeightAtWidth(
                    measureWidth: restWidth,
                    child: SizedBox(
                      width: restWidth,
                      child: _buildScrollableHeader(
                          canViewFinance, restWidth),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      // ── Data rows ──────────────────────────────────────────────────────
      // Контент строки собирается один раз и передаётся через `child`
      // per-row ValueListenableBuilder'а; на тик скролла пересоздаётся
      // только обёртка Transform.translate (repaint матрицы, ноль
      // пересборок контента). Hover локален для каждой HoverableRow.
      // GestureDetector — горизонтальный drag над данными (см.
      // _onRowsHorizontalDrag); тапы и вертикальный скролл проходят.
      final dataRows = GestureDetector(
        onHorizontalDragUpdate: _onRowsHorizontalDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++)
              HoverableRow(
                builder: (hovered) => IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildStickyDataCell(rows[i], stickyWidth, hovered),
                      Expanded(
                        child: StickyScrollArea(
                          child: ClipRect(
                            // OverflowBox разрывает tight-ширину ячейки:
                            // без него SizedBox(restWidth) схлопывался до
                            // видимой области и все колонки утрамбовыва-
                            // лись в экран (рассинхрон с заголовком).
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: 0,
                              maxWidth: double.infinity,
                              child: ValueListenableBuilder<double>(
                                valueListenable: _sync.offsetNotifier,
                                child: IntrinsicHeightAtWidth(
                                  measureWidth: restWidth,
                                  child: SizedBox(
                                    width: restWidth,
                                    child: _buildScrollableDataRow(
                                        context,
                                        rows[i],
                                        canViewFinance,
                                        canEdit,
                                        i,
                                        hovered,
                                        nightPercent,
                                        mealAmount),
                                  ),
                                ),
                                builder: (context, hOffset, child) =>
                                    Transform.translate(
                                  offset: Offset(-hOffset, 0),
                                  child: child,
                                ),
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
        ),
      );

      // ── Footer row ───────────────────────────────────────────────────
      final footerRow = IntrinsicHeight(
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
                  child: IntrinsicHeightAtWidth(
                    measureWidth: restWidth,
                    child: SizedBox(
                      width: restWidth,
                      child:
                          _buildScrollableFooter(canViewFinance, totals),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      // Высота не ограничена — таблица лежит во внешнем вертикальном
      // скролле (прежняя схема, так же собирают виджет тесты): цельная
      // колонка без закрепления, скроллит родитель.
      if (!constraints.maxHeight.isFinite) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [headerRow, dataRows, footerRow],
        );
      }

      // Ограниченная высота: шапка столбцов закреплена сверху и всегда
      // видима, строки и футер прокручиваются вертикально под ней.
      // Горизонтальная синхронизация шапки со строками не меняется —
      // шапка остаётся в той же группе HScrollSync (_ctrl(-1)).
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          headerRow,
          Expanded(
            child: SingleChildScrollView(
              controller: _verticalCtrl,
              primary: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [dataRows, footerRow],
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildScrollableHeader(bool finance, double width) {
    final cols = <String>[
      'Смены',
      'Дни',
      'Ночи',
      'Рабочие места',
      'Средняя скорость',
      'Паузы',
      'Проблемы',
      'Претензии',
      if (finance) 'Сдельно / оклад',
      if (finance) 'Оплата приладки',
      if (finance) 'Средняя сдельная',
      if (finance) 'Оплата ночных',
      if (finance) 'Компенсация',
      if (finance) 'Соцотчисления',
      if (finance) 'Питание',
      if (finance) 'Аванс',
      if (finance) 'ЗП без нал',
      if (finance) 'Дисциплина',
      if (finance) 'Браки',
      if (finance) 'Итог ЗП',
      if (finance) 'Ведомость',
    ];
    return Container(
      decoration: const BoxDecoration(gradient: AnalyticsColors.tableHeaderGradient),
      child: Row(
        children: cols.map((label) {
          final flex =
              (label == 'Рабочие места' || label == 'Средняя скорость') ? 2 : 1;
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
        child: _EmployeeCell(
            employee: r.employee, status: r.statusName, position: r.positionNames),
      ),
    );
  }

  Widget _buildScrollableDataRow(BuildContext context, _Row r, bool finance,
      bool canEdit, int index, bool hovered, double nightPercent,
      double mealAmount) {
    // Все агрегаты предвычислены в _buildRows (см. _Row) — build ячеек
    // не должен трогать AnalyticsCalculator.
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
            _cell(
              child: _twoLine(
                Text('${r.breakdown.shiftsTotal}', style: _cellStyle()),
                Text('смен', style: _mutedStyle()),
              ),
            ),
            _cell(child: Text('${r.breakdown.dayShifts}', style: _cellStyle())),
            _cell(
                child:
                    Text('${r.breakdown.nightShifts}', style: _cellStyle())),
            // Рабочие места: общее время, сделанное количество, приладки.
            _cell(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: r.workplaceStats.isEmpty
                    ? [Text('—', style: _mutedStyle())]
                    : r.workplaceStats
                        .map((s) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '${s.name}: '
                                '${AnalyticsFormat.hoursMinutes(s.totalMinutes)} · '
                                '${AnalyticsFormat.decimal(s.qty)} ${s.unit} · '
                                '${AnalyticsFormat.decimal(s.setupQty)} прил.',
                                style: _cellStyle().copyWith(fontSize: 11),
                              ),
                            ))
                        .toList(),
              ),
            ),
            // Средняя скорость: минуты на приладку и минуты на единицу.
            _cell(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: r.workplaceStats.isEmpty
                    ? [Text('—', style: _mutedStyle())]
                    : r.workplaceStats
                        .map((s) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '${s.name}: '
                                '${_perUnit(s)} · ${_perSetup(s)}',
                                style: _cellStyle().copyWith(fontSize: 11),
                              ),
                            ))
                        .toList(),
              ),
            ),
            _cell(
              child: _twoLine(
                Text('${r.pauseCount}', style: _cellStyle()),
                Text(AnalyticsFormat.hoursMinutes(r.pauseMinutes),
                    style: _mutedStyle()),
              ),
            ),
            _cell(
              child: _twoLine(
                Text('${r.problemCount}', style: _cellStyle()),
                Text(AnalyticsFormat.hoursMinutes(r.problemMinutes),
                    style: _mutedStyle()),
              ),
            ),
            _cell(child: _claimsCell(r)),
            // ── Финансовые колонки ────────────────────────────────────────
            if (finance) _cell(child: _payTypeChip(r)),
            if (finance)
              _cell(
                  child: _twoLine(
                Text(AnalyticsFormat.money(r.breakdown.setupPay),
                    style: _cellStyle()),
                Text(
                  '${AnalyticsFormat.decimal(r.breakdown.setupPayQty)} прил.',
                  style: _mutedStyle(),
                ),
              )),
            if (finance)
              _cell(
                  child: Text(
                      AnalyticsFormat.money(r.breakdown.averageShiftSalary),
                      style: _cellStyle())),
            if (finance)
              _cell(
                  child: _twoLine(
                Text(AnalyticsFormat.money(r.breakdown.nightBonus),
                    style: _cellStyle()),
                Text(
                  '${r.breakdown.nightShifts} ноч. · ${nightPercent.toStringAsFixed(0)}%',
                  style: _mutedStyle(),
                ),
              )),
            // Компенсация — редактируемое поле (renderInlineMoneyInput).
            if (finance)
              _inputCell(r, r.breakdown.compensation, canEdit,
                  (base, v) => base.copyWith(compensation: v)),
            if (finance)
              _inputCell(r, r.breakdown.social, canEdit,
                  (base, v) => base.copyWith(social: v)),
            // Питание — вычисляемое: смены × цена порции.
            if (finance)
              _cell(
                  child: _twoLine(
                Text(AnalyticsFormat.money(r.breakdown.mealDeduction),
                    style: _cellStyle()),
                Text(
                  '${r.breakdown.shiftsTotal} порц. × ${AnalyticsFormat.money(mealAmount)}',
                  style: _mutedStyle(),
                ),
              )),
            if (finance)
              _inputCell(r, r.breakdown.advance, canEdit,
                  (base, v) => base.copyWith(advance: v)),
            if (finance)
              _inputCell(r, r.breakdown.cashless, canEdit,
                  (base, v) => base.copyWith(cashless: v)),
            if (finance)
              _inputCell(r, r.breakdown.discipline, canEdit,
                  (base, v) => base.copyWith(discipline: v)),
            if (finance)
              _inputCell(r, r.breakdown.defect, canEdit,
                  (base, v) => base.copyWith(defect: v)),
            if (finance)
              _cell(
                  child: Text(AnalyticsFormat.money(r.breakdown.total),
                      style: _cellStyle()
                          .copyWith(fontWeight: FontWeight.w900))),
            if (finance)
              _cell(
                  child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _statementExportingFor == r.employee.id
                      ? null
                      : () => _exportStatement(r),
                  child: Text(
                    _statementExportingFor == r.employee.id
                        ? 'Создаём…'
                        : 'Ведомость',
                    style: const TextStyle(color: AnalyticsColors.blue),
                  ),
                ),
              )),
          ],
        ),
      ),
    );
  }

  /// Ведомость сотрудника за месяц — PDF на один А4 (Фаза 6). Документ
  /// финансовый, гейт canExportPdf; колонка и так видна только при
  /// canViewFinance.
  Future<void> _exportStatement(_Row r) async {
    if (!widget.permission.canExportPdf) return;
    if (_statementExportingFor != null) return;
    setState(() => _statementExportingFor = r.employee.id);
    try {
      final path = await _pdfService.exportEmployeeSalaryStatementPdf(
        service: widget.service,
        personnel: widget.personnel,
        employeeId: r.employee.id,
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать ведомость: $e')),
      );
    } finally {
      if (mounted) setState(() => _statementExportingFor = null);
    }
  }

  /// Число претензий. При count > 0 — кликабельно (подчёркнутое синее),
  /// тап поглощается GestureDetector'ом по образцу _inputCell и открывает
  /// диалог списка, НЕ деталку. Ноль — обычный текст, некликабелен.
  Widget _claimsCell(_Row r) {
    if (r.claims == 0) {
      return Text('0',
          key: ValueKey('claims-${r.employee.id}'), style: _cellStyle());
    }
    return GestureDetector(
      key: ValueKey('claims-${r.employee.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _openClaimsDialog(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          '${r.claims}',
          style: _cellStyle().copyWith(
            color: AnalyticsColors.blue,
            decoration: TextDecoration.underline,
            decorationColor: AnalyticsColors.blue,
          ),
        ),
      ),
    );
  }

  void _openClaimsDialog(_Row r) {
    final state = _lastState;
    if (state == null) return;
    final claims = state.claims
        .where((c) => c.employeeId == r.employee.id)
        .toList(growable: false);
    final month = state.month;
    showClaimsListDialog(
      context,
      employeeName:
          '${r.employee.lastName} ${r.employee.firstName}'.trim(),
      monthLabel:
          '${month.month.toString().padLeft(2, '0')}.${month.year}',
      claims: claims,
    );
  }

  /// Ячейка с редактируемым денежным полем. Тап по инпуту (и по паддингу
  /// вокруг него) поглощается GestureDetector'ом — клик не всплывает до
  /// InkWell строки и не открывает деталку (аналог stopPropagation).
  Widget _inputCell(
    _Row r,
    double value,
    bool enabled,
    SalaryAdjustments Function(SalaryAdjustments base, double v) apply,
  ) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: _InlineMoneyField(
            value: value,
            enabled: enabled,
            onSaved: (v) => _saveAdjustment(r, (base) => apply(base, v)),
          ),
        ),
      ),
    );
  }

  /// Оптимистичное сохранение корректировки. При ошибке сервис откатывает
  /// состояние и пробрасывает исключение — показываем SnackBar.
  Future<void> _saveAdjustment(
      _Row r, SalaryAdjustments Function(SalaryAdjustments base) update) async {
    final state = widget.service.state;
    final base = state.adjustments[r.employee.id] ??
        SalaryAdjustments.zero(r.employee.id, state.month.firstDay);
    try {
      await widget.service.saveSalaryAdjustments(update(base));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    }
  }

  Widget _payTypeChip(_Row r) {
    // Тип и сумма — из единого расчёта (SalaryCalculator): окладник →
    // окладная (смены × ставка), сдельщик → сдельная. primaryEarned — та же
    // сумма, что входит в accrued/total.
    final isSalary = r.breakdown.isSalaryType;
    final label = isSalary ? 'Оклад' : 'Сдельно';
    final amount = r.breakdown.primaryEarned;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x1A38BDF8),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x3338BDF8)),
        ),
        child: Text(
          '$label: ${AnalyticsFormat.money(amount)}',
          style: const TextStyle(
            color: Color(0xFF7DD3FC),
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _buildScrollableFooter(bool finance, _FooterTotals t) {
    Widget c(String label, String value, {int flex = 1}) =>
        Expanded(flex: flex, child: _footerCell(label, value));

    return Container(
      decoration: BoxDecoration(
        color: AnalyticsColors.footerBg,
        border: Border(
            top: BorderSide(
                color: AnalyticsColors.green.withOpacity(0.24), width: 1)),
      ),
      child: Row(
        children: [
          c('смен', '${t.shifts}'),
          c('дней', '${t.days}'),
          c('ночей', '${t.nights}'),
          // Суммарное qty здесь не показываем — рабочие места считают в
          // разных единицах измерения, их сумма не имеет смысла (та же
          // причина, по которой убрана колонка «Сделано»).
          c(
              'всего',
              'приладка ${AnalyticsFormat.decimal(t.setupAll)} / ${AnalyticsFormat.hoursMinutes(t.usefulM)}',
              flex: 2),
          // Средние скорости считаются по рабочим местам в разных единицах,
          // поэтому общий итог по колонке смысла не имеет.
          c('средняя скорость', '—', flex: 2),
          c('паузы',
              '${t.pauseCount} · ${AnalyticsFormat.hoursMinutes(t.pauseM)}'),
          c('проблемы',
              '${t.problemCount} · ${AnalyticsFormat.hoursMinutes(t.problemM)}'),
          c('претензии', '${t.claimsAll}'),
          if (finance) c('сдельно/оклад', AnalyticsFormat.money(t.earnedSum)),
          if (finance) c('приладка', AnalyticsFormat.money(t.setupPaySum)),
          if (finance) c('средняя', AnalyticsFormat.money(t.avgPiece)),
          if (finance) c('ночные', AnalyticsFormat.money(t.nightSum)),
          if (finance) c('комп.', AnalyticsFormat.money(t.compSum)),
          if (finance) c('соц.', AnalyticsFormat.money(t.socialSum)),
          if (finance) c('питание', AnalyticsFormat.money(t.mealSum)),
          if (finance) c('аванс', AnalyticsFormat.money(t.advSum)),
          if (finance) c('безнал', AnalyticsFormat.money(t.cashSum)),
          if (finance) c('дисц.', AnalyticsFormat.money(t.discSum)),
          if (finance) c('браки', AnalyticsFormat.money(t.defSum)),
          if (finance) c('итог ЗП', AnalyticsFormat.money(t.salarySum)),
          if (finance) c('', '—'),
        ],
      ),
    );
  }

  /// «12,5 мин/прил.» либо «—», если приладок не было.
  static String _perSetup(_WorkplaceStat s) {
    final value = s.minutesPerSetup;
    return value == null
        ? '— мин/прил.'
        : '${AnalyticsFormat.decimal(value, precision: 1)} мин/прил.';
  }

  /// «12,50 шт/мин» либо «—», если производственного времени не было.
  static String _perUnit(_WorkplaceStat s) {
    final value = s.qtyPerMinute;
    return value == null
        ? '— ${s.unit}/мин'
        : '${AnalyticsFormat.decimal(value)} ${s.unit}/мин';
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

  /// Двухстрочная ячейка (значение + подпись). Высоту строке обеспечивает
  /// IntrinsicHeight по реальному контенту (см. StickyScrollArea) — ужимать
  /// содержимое не нужно, а FittedBox лишь маскировал бы регрессии высоты.
  static Widget _twoLine(Widget top, Widget bottom) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [top, bottom],
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
}

/// Предвычисленные суммы футера (все колонки эталона суммируются).
class _FooterTotals {
  final int shifts;
  final int days;
  final int nights;
  final double setupAll;
  final int usefulM;
  final int pauseCount;
  final int pauseM;
  final int problemCount;
  final int problemM;
  final int claimsAll;
  final double pieceSum;
  final double earnedSum;
  final double avgPiece;
  final double nightSum;
  final double compSum;
  final double socialSum;
  final double mealSum;
  final double advSum;
  final double cashSum;
  final double discSum;
  final double defSum;
  final double salarySum;
  final double setupPaySum;

  const _FooterTotals({
    required this.shifts,
    required this.days,
    required this.nights,
    required this.setupAll,
    required this.usefulM,
    required this.pauseCount,
    required this.pauseM,
    required this.problemCount,
    required this.problemM,
    required this.claimsAll,
    required this.pieceSum,
    required this.earnedSum,
    required this.avgPiece,
    required this.nightSum,
    required this.compSum,
    required this.socialSum,
    required this.mealSum,
    required this.advSum,
    required this.cashSum,
    required this.discSum,
    required this.defSum,
    required this.salarySum,
    required this.setupPaySum,
  });
}

/// Инлайн-инпут денежной корректировки.
///
/// Контроллер и FocusNode живут в СОСТОЯНИИ этого виджета, а не в
/// builder'е Transform.translate строки. На тик горизонтального скролла
/// ValueListenableBuilder переиспользует один и тот же `child` (Element
/// поля сохраняется) — контроллер НЕ пересоздаётся, ввод/курсор не
/// сбрасываются. Утилизация — в [dispose] этого State (автоматически, когда
/// строка покидает дерево). Сохранение — по потере фокуса или Enter, не на
/// каждый символ.
class _InlineMoneyField extends StatefulWidget {
  const _InlineMoneyField({
    required this.value,
    required this.enabled,
    required this.onSaved,
  });

  final double value;
  final bool enabled;
  final ValueChanged<double> onSaved;

  @override
  State<_InlineMoneyField> createState() => _InlineMoneyFieldState();
}

class _InlineMoneyFieldState extends State<_InlineMoneyField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  // Последнее зафиксированное значение — чтобы Enter и следующая за ним
  // потеря фокуса не дали двойного сохранения (onSubmitted + blur), не
  // полагаясь на round-trip состояния.
  late double _lastCommitted;

  @override
  void initState() {
    super.initState();
    _lastCommitted = widget.value;
    _ctrl = TextEditingController(text: _fmt(widget.value));
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _InlineMoneyField old) {
    super.didUpdateWidget(old);
    // Внешнее значение изменилось (оптимистичное сохранение или откат) —
    // синхронизируем текст ТОЛЬКО когда поле не в фокусе, чтобы не затирать
    // то, что пользователь печатает прямо сейчас.
    if (!_focus.hasFocus && widget.value != old.value) {
      _lastCommitted = widget.value;
      _ctrl.text = _fmt(widget.value);
    }
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final parsed = double.tryParse(
          _ctrl.text.replaceAll(' ', '').replaceAll(' ', '').replaceAll(',', '.'),
        ) ??
        0;
    if (parsed != _lastCommitted) {
      _lastCommitted = parsed;
      widget.onSaved(parsed);
    }
  }

  static String _fmt(double v) => v.round().toString();

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _ctrl,
        focusNode: _focus,
        enabled: widget.enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        textAlignVertical: TextAlignVertical.center,
        onSubmitted: (_) => _commit(),
        style: const TextStyle(
            color: AnalyticsColors.text,
            fontSize: 12,
            fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true,
          fillColor: const Color(0x1102061B),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AnalyticsColors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AnalyticsColors.blue),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

class _Row {
  final EmployeeModel employee;
  final List<AnalyticsEvent> events;
  final String? statusName;
  final String positionNames;
  final PayType? payType;
  final SalaryBreakdown breakdown;
  final int claims;

  // Предвычисленные агрегаты строки (см. _buildRows): считаются один раз
  // на смену AnalyticsState, а не в build ячеек на каждый rebuild.
  final int pauseCount;
  final int pauseMinutes;
  final int problemCount;
  final int problemMinutes;
  final double setupQty;
  final List<_WorkplaceStat> workplaceStats;

  const _Row({
    required this.employee,
    required this.events,
    required this.statusName,
    required this.positionNames,
    required this.payType,
    required this.breakdown,
    required this.claims,
    required this.pauseCount,
    required this.pauseMinutes,
    required this.problemCount,
    required this.problemMinutes,
    required this.setupQty,
    required this.workplaceStats,
  });
}

/// Показатели сотрудника на одном рабочем месте за период.
class _WorkplaceStat {
  final String name;
  final String unit;
  final int totalMinutes;
  final int productionMinutes;
  final int setupMinutes;
  final double qty;
  final double setupQty;

  const _WorkplaceStat({
    required this.name,
    required this.unit,
    required this.totalMinutes,
    required this.productionMinutes,
    required this.setupMinutes,
    required this.qty,
    required this.setupQty,
  });

  /// Средняя длительность одной приладки: время наладки ÷ количество приладок.
  /// null — приладок не было, делить не на что.
  double? get minutesPerSetup =>
      setupQty > 0 ? setupMinutes / setupQty : null;

  /// Средняя выработка: количество ÷ время производства (единиц в минуту).
  /// null — производственного времени не было, делить не на что.
  double? get qtyPerMinute =>
      productionMinutes > 0 ? qty / productionMinutes : null;
}

class _EmployeeCell extends StatelessWidget {
  const _EmployeeCell(
      {required this.employee, required this.status, this.position});
  final EmployeeModel employee;
  final String? status;
  final String? position;

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
              if (position != null && position!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    position!,
                    style: const TextStyle(
                      color: AnalyticsColors.muted,
                      fontSize: 11,
                    ),
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
