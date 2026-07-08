import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../personnel/personnel_provider.dart';
import '../../personnel/workplace_model.dart';
import '../calculators/analytics_calculator.dart';
import '../calculators/kpd_calculator.dart';
import '../models/analytics_event.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/format_utils.dart';
import '../utils/h_scroll_sync.dart';
import 'analytics_table_parts.dart';

class WorkplacesTable extends StatefulWidget {
  const WorkplacesTable({
    super.key,
    required this.service,
    required this.personnel,
    required this.canEditCoefficient,
    required this.onWorkplaceTap,
  });

  final AnalyticsService service;
  final PersonnelProvider personnel;
  final bool canEditCoefficient;
  final ValueChanged<String> onWorkplaceTap;

  @override
  State<WorkplacesTable> createState() => _WorkplacesTableState();
}

class _WorkplacesTableState extends State<WorkplacesTable> {
  final HScrollSync _sync = HScrollSync();
  final Map<int, ScrollController> _ctrlCache = {};

  // Row computation cache.
  AnalyticsState? _lastState;
  List<_WpRow> _rows = const [];

  ScrollController _ctrl(int key) =>
      _ctrlCache.putIfAbsent(key, () => _sync.acquire());

  void _maybeRecompute(AnalyticsState state) {
    if (state.loading) return;
    if (identical(state, _lastState)) return;
    _lastState = state;
    _rows = _buildRows(state);
  }

  List<_WpRow> _buildRows(AnalyticsState state) {
    final events = state.events;
    final byWp = <String, List<AnalyticsEvent>>{};
    for (final e in events) {
      byWp.putIfAbsent(e.workplaceId, () => []).add(e);
    }
    final claimsByWp = <String, int>{};
    for (final c in state.claims) {
      final wpId = c.workplaceId ?? '';
      if (wpId.isEmpty) continue;
      claimsByWp[wpId] = (claimsByWp[wpId] ?? 0) + 1;
    }

    return widget.personnel.workplaces.map((wp) {
      final list = byWp[wp.id] ?? const <AnalyticsEvent>[];
      final pause =
          list.where((e) => e.type == AnalyticsEventType.pause).toList();
      final problem =
          list.where((e) => e.type == AnalyticsEventType.problem).toList();

      final currentSpeed = AnalyticsCalculator.speedQtyPerMinute(list);
      final kpd = KpdCalculator.compute(
        currentSpeed: currentSpeed,
        previousMonthsSpeeds:
            state.workplacePreviousSpeeds[wp.id] ?? const [],
      );

      final ordersCount = <String>{};
      for (final e in list) {
        if (e.type == AnalyticsEventType.work && e.orderId.isNotEmpty) {
          ordersCount.add(e.orderId);
        }
      }

      return _WpRow(
        workplace: wp,
        events: list,
        qty: AnalyticsCalculator.totalQty(list),
        usefulMinutes: AnalyticsCalculator.usefulMinutes(list),
        setupQty: AnalyticsCalculator.totalSetupQty(list),
        setupMinutes: AnalyticsCalculator.setupMinutes(list),
        pauseCount: pause.length,
        pauseMinutes: AnalyticsCalculator.pauseMinutes(pause),
        problemCount: problem.length,
        problemMinutes: AnalyticsCalculator.problemMinutes(problem),
        ordersCount: ordersCount.length,
        claims: claimsByWp[wp.id] ?? 0,
        speed: currentSpeed,
        kpd: kpd,
        coefficient: state.coefficients[wp.id] ?? 0,
      );
    }).toList();
  }

  @override
  void didUpdateWidget(covariant WorkplacesTable oldWidget) {
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
    _sync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state;
    _maybeRecompute(state);
    final rows = _rows;

    // Sticky column: 260 px. Rest: min 1280 px.
    const stickyWidth = 260.0;
    const restMinWidth = 1280.0;

    return LayoutBuilder(builder: (context, constraints) {
      final restWidth = constraints.maxWidth.isFinite
          ? math.max(constraints.maxWidth - stickyWidth, restMinWidth)
          : restMinWidth;

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header row ─────────────────────────────────────────────────
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _stickyHeaderCell(stickyWidth),
                Expanded(
                  child: StickyScrollArea(
                    child: SingleChildScrollView(
                      controller: _ctrl(-1),
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: SizedBox(
                        width: restWidth,
                        child: _scrollableHeader(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Data rows ──────────────────────────────────────────────────
          // Контент строки собирается один раз и передаётся через `child`
          // per-row ValueListenableBuilder'а; на тик скролла пересоздаётся
          // только обёртка Transform.translate (repaint матрицы, ноль
          // пересборок контента). Hover локален для каждой HoverableRow.
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rows.length; i++)
                HoverableRow(
                  builder: (hovered) => IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _stickyDataCell(rows[i], stickyWidth, hovered),
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
                                  child: SizedBox(
                                    width: restWidth,
                                    child: _scrollableDataRow(
                                        rows[i], i, hovered),
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
        ],
      );
    });
  }

  Widget _stickyHeaderCell(double width) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
          gradient: AnalyticsColors.tableStickyHeaderGradient),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: const Text(
        'РАБОЧЕЕ МЕСТО',
        style: TextStyle(
          color: AnalyticsColors.tableHeaderText,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _scrollableHeader() {
    Widget cell(String s, {int flex = 1}) => Expanded(
          flex: flex,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Text(
              s.toUpperCase(),
              style: const TextStyle(
                color: AnalyticsColors.tableHeaderText,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
        );
    return Container(
      decoration:
          const BoxDecoration(gradient: AnalyticsColors.tableHeaderGradient),
      child: Row(
        children: [
          cell('Ед. изм.'),
          cell('Коэффициент'),
          cell('Количество / время / скорость', flex: 2),
          cell('Наладки / время / скорость', flex: 2),
          cell('Заказы'),
          cell('Паузы'),
          cell('Проблемы'),
          cell('Претензии'),
          cell('КПД'),
        ],
      ),
    );
  }

  Widget _stickyDataCell(_WpRow r, double width, bool hovered) {
    return InkWell(
      onTap: () => widget.onWorkplaceTap(r.workplace.id),
      child: Container(
        width: width,
        decoration: BoxDecoration(
          gradient: hovered
              ? AnalyticsColors.tableStickyHoverGradient
              : AnalyticsColors.tableStickyColumnGradient,
          border:
              const Border(bottom: BorderSide(color: AnalyticsColors.line)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          r.workplace.name,
          style: const TextStyle(
            color: AnalyticsColors.text,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _scrollableDataRow(_WpRow r, int index, bool hovered) {
    final unit = r.workplace.unit?.trim().isNotEmpty == true
        ? r.workplace.unit!
        : 'ед.';
    final avgQtySpeed =
        r.usefulMinutes > 0 ? r.qty / r.usefulMinutes : 0.0;
    final avgSetupSpeed =
        r.setupMinutes > 0 ? r.setupQty / r.setupMinutes : 0.0;
    final rowColor = hovered
        ? AnalyticsColors.rowHover
        : (index.isEven ? AnalyticsColors.zebraOdd : AnalyticsColors.zebraEven);

    return InkWell(
      onTap: () => widget.onWorkplaceTap(r.workplace.id),
      child: Container(
        decoration: BoxDecoration(
          color: rowColor,
          border:
              const Border(bottom: BorderSide(color: AnalyticsColors.line)),
        ),
        child: Row(
          children: [
            _cell(unit),
            _cell(AnalyticsFormat.decimal(r.coefficient)),
            _cellLong(
              '${AnalyticsFormat.decimal(r.qty)} $unit',
              '${AnalyticsFormat.hoursMinutes(r.usefulMinutes)} · ${AnalyticsFormat.decimal(avgQtySpeed)} $unit/мин',
            ),
            _cellLong(
              '${AnalyticsFormat.decimal(r.setupQty)}',
              '${AnalyticsFormat.hoursMinutes(r.setupMinutes)} · ${AnalyticsFormat.decimal(avgSetupSpeed)} нал/мин',
            ),
            _cell('${r.ordersCount}'),
            // flex: 1 — веса ячеек данных обязаны совпадать с _scrollableHeader
            // ([1,1,2,2,1,1,1,1,1]), иначе колонки съезжают от заголовка.
            _cellLong(
                '${r.pauseCount}',
                AnalyticsFormat.hoursMinutes(r.pauseMinutes),
                flex: 1),
            _cellLong(
                '${r.problemCount}',
                AnalyticsFormat.hoursMinutes(r.problemMinutes),
                flex: 1),
            _cell('${r.claims}'),
            _cellLong(
              '${r.kpd.kpdPercent.round()}%',
              r.kpd.noBaseline
                  ? 'нет базы — безопасный fallback'
                  : 'к средней базе всех прошлых месяцев',
              flex: 1,
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(String v, {int flex = 1}) => Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            v,
            style:
                const TextStyle(color: AnalyticsColors.text, fontSize: 12),
          ),
        ),
      );

  Widget _cellLong(String top, String sub, {int flex = 2}) => Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(top,
                  style: const TextStyle(
                    color: AnalyticsColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  )),
              Text(sub,
                  style: const TextStyle(
                    color: AnalyticsColors.muted,
                    fontSize: 11,
                  )),
            ],
          ),
        ),
      );
}

class _WpRow {
  final WorkplaceModel workplace;
  final List<AnalyticsEvent> events;
  final double qty;
  final int usefulMinutes;
  final double setupQty;
  final int setupMinutes;
  final int pauseCount;
  final int pauseMinutes;
  final int problemCount;
  final int problemMinutes;
  final int ordersCount;
  final int claims;
  final double speed;
  final KpdResult kpd;
  final double coefficient;

  const _WpRow({
    required this.workplace,
    required this.events,
    required this.qty,
    required this.usefulMinutes,
    required this.setupQty,
    required this.setupMinutes,
    required this.pauseCount,
    required this.pauseMinutes,
    required this.problemCount,
    required this.problemMinutes,
    required this.ordersCount,
    required this.claims,
    required this.speed,
    required this.kpd,
    required this.coefficient,
  });
}
