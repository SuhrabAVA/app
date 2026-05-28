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

class WorkplacesTable extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final state = service.state;
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

    final rows = personnel.workplaces.map((wp) {
      final list = byWp[wp.id] ?? const <AnalyticsEvent>[];
      final pause =
          list.where((e) => e.type == AnalyticsEventType.pause).toList();
      final problem =
          list.where((e) => e.type == AnalyticsEventType.problem).toList();

      final currentSpeed =
          AnalyticsCalculator.speedQtyPerMinute(list);
      final kpd = KpdCalculator.compute(
        currentSpeed: currentSpeed,
        previousMonthsSpeeds: state.workplacePreviousSpeeds[wp.id] ?? const [],
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

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite
          ? math.max(constraints.maxWidth, 1500.0)
          : 1500.0;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(),
              ...rows.map(_buildRow),
            ],
          ),
        ),
      );
    });
  }

  Widget _header() {
    Widget cell(String s, {int flex = 1}) => Expanded(
          flex: flex,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Text(
              s.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        );
    return Container(
      decoration: const BoxDecoration(color: Color(0xFF121A2E)),
      child: Row(
        children: [
          cell('Рабочее место', flex: 2),
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

  Widget _buildRow(_WpRow r) {
    final unit =
        r.workplace.unit?.trim().isNotEmpty == true ? r.workplace.unit! : 'ед.';
    final avgQtySpeed =
        r.usefulMinutes > 0 ? r.qty / r.usefulMinutes : 0.0;
    final avgSetupSpeed =
        r.setupMinutes > 0 ? r.setupQty / r.setupMinutes : 0.0;

    return InkWell(
      onTap: () => onWorkplaceTap(r.workplace.id),
      child: Container(
        decoration: BoxDecoration(
          color: AnalyticsColors.card2.withOpacity(0.55),
          border: Border(bottom: BorderSide(color: AnalyticsColors.line)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Text(
                  r.workplace.name,
                  style: const TextStyle(
                    color: AnalyticsColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
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
            _cellLong('${r.pauseCount}',
                AnalyticsFormat.hoursMinutes(r.pauseMinutes)),
            _cellLong('${r.problemCount}',
                AnalyticsFormat.hoursMinutes(r.problemMinutes)),
            _cell('${r.claims}'),
            _cellLong(
              '${r.kpd.kpdPercent.round()}%',
              r.kpd.noBaseline ? 'нет базы' : 'к предыдущим месяцам',
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(String v, {int flex = 1}) => Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Text(
            v,
            style: const TextStyle(color: AnalyticsColors.text, fontSize: 12),
          ),
        ),
      );

  Widget _cellLong(String top, String sub, {int flex = 2}) => Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
