import 'package:flutter/material.dart';

import '../../personnel/workplace_model.dart';
import '../calculators/analytics_calculator.dart';
import '../models/analytics_event.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';

/// Сводка по одному рабочему месту сотрудника.
class WorkplaceSummaryRow {
  final String workplaceId;
  final WorkplaceModel? workplace;
  final int pauseCount;
  final int pauseMinutes;
  final int problemCount;
  final int problemMinutes;
  final double qty;
  final int workMinutes;
  final double speed;
  final int claims;

  const WorkplaceSummaryRow({
    required this.workplaceId,
    required this.workplace,
    required this.pauseCount,
    required this.pauseMinutes,
    required this.problemCount,
    required this.problemMinutes,
    required this.qty,
    required this.workMinutes,
    required this.speed,
    required this.claims,
  });

  String get unit => workplace?.unit?.trim().isNotEmpty == true
      ? workplace!.unit!.trim()
      : 'ед.';
  String get name => workplace?.name ?? workplaceId;
}

WorkplaceSummaryRow buildWorkplaceSummary({
  required String workplaceId,
  required WorkplaceModel? workplace,
  required List<AnalyticsEvent> events,
  required int claims,
}) {
  final pause = events.where((e) => e.type == AnalyticsEventType.pause).toList();
  final problem =
      events.where((e) => e.type == AnalyticsEventType.problem).toList();
  final pauseM = AnalyticsCalculator.pauseMinutes(pause);
  final problemM = AnalyticsCalculator.problemMinutes(problem);
  final qty = AnalyticsCalculator.totalQty(events);
  final usefulM = AnalyticsCalculator.usefulMinutes(events);
  final speed = usefulM > 0 ? qty / usefulM : 0.0;
  return WorkplaceSummaryRow(
    workplaceId: workplaceId,
    workplace: workplace,
    pauseCount: pause.length,
    pauseMinutes: pauseM,
    problemCount: problem.length,
    problemMinutes: problemM,
    qty: qty,
    workMinutes: usefulM,
    speed: speed,
    claims: claims,
  );
}

class EmployeeWorkplaceStrip extends StatelessWidget {
  const EmployeeWorkplaceStrip({
    super.key,
    required this.rows,
    required this.activeFilter,
    required this.onChangeFilter,
  });

  final List<WorkplaceSummaryRow> rows;
  final String activeFilter;
  final ValueChanged<String> onChangeFilter;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 168,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        children: [
          _AllCard(
            isActive: activeFilter == AnalyticsConstants.allWorkplaces,
            onTap: () =>
                onChangeFilter(AnalyticsConstants.allWorkplaces),
          ),
          for (final row in rows) ...[
            const SizedBox(width: 12),
            _WorkplaceCard(
              row: row,
              isActive: activeFilter == row.workplaceId,
              onTap: () => onChangeFilter(row.workplaceId),
            ),
          ],
        ],
      ),
    );
  }
}

class _AllCard extends StatelessWidget {
  const _AllCard({required this.isActive, required this.onTap});
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _CardContainer(
      isActive: isActive,
      onTap: onTap,
      child: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.layers_outlined,
                  size: 32, color: AnalyticsColors.blue),
              SizedBox(height: 8),
              Text('Все',
                  style: TextStyle(
                    color: AnalyticsColors.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  )),
              SizedBox(height: 4),
              Text(
                'Все рабочие места',
                style: TextStyle(color: AnalyticsColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkplaceCard extends StatelessWidget {
  const _WorkplaceCard({
    required this.row,
    required this.isActive,
    required this.onTap,
  });
  final WorkplaceSummaryRow row;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _CardContainer(
      isActive: isActive,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AnalyticsColors.text,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            _kv('Паузы',
                '${row.pauseCount} · ${AnalyticsFormat.hoursMinutes(row.pauseMinutes)}'),
            _kv('Проблемы',
                '${row.problemCount} · ${AnalyticsFormat.hoursMinutes(row.problemMinutes)}'),
            _kv('Сделано',
                '${AnalyticsFormat.decimal(row.qty)} ${row.unit} · ${AnalyticsFormat.hoursMinutes(row.workMinutes)}'),
            _kv('Скорость',
                '${AnalyticsFormat.decimal(row.speed)} ${row.unit}/мин'),
            _kv('Претензии', '${row.claims}'),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(
          children: [
            Expanded(
              child: Text(
                k,
                style: const TextStyle(
                    color: AnalyticsColors.muted, fontSize: 11),
              ),
            ),
            Text(
              v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AnalyticsColors.text,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
}

class _CardContainer extends StatelessWidget {
  const _CardContainer({
    required this.child,
    required this.isActive,
    required this.onTap,
  });
  final Widget child;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: 240,
        decoration: BoxDecoration(
          color: const Color(0x5902061B),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isActive
                ? AnalyticsColors.blue
                : AnalyticsColors.line,
            width: isActive ? 2 : 1,
          ),
          boxShadow: isActive
              ? const [
                  BoxShadow(
                    color: Color(0x2238BDF8),
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
        child: child,
      ),
    );
  }
}
