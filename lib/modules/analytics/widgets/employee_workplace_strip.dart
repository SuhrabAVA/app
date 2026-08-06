import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
  final pause =
      events.where((e) => e.type == AnalyticsEventType.pause).toList();
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

class EmployeeWorkplaceStrip extends StatefulWidget {
  const EmployeeWorkplaceStrip({
    super.key,
    required this.rows,
    required this.activeFilter,
    required this.onChangeFilter,
    this.onOpenIncidents,
  });

  final List<WorkplaceSummaryRow> rows;
  final String activeFilter;
  final ValueChanged<String> onChangeFilter;

  /// Открыть разбор простоев рабочего места: паузы или проблемы.
  final void Function(String workplaceId, AnalyticsEventType type)?
      onOpenIncidents;

  @override
  State<EmployeeWorkplaceStrip> createState() => _EmployeeWorkplaceStripState();
}

class _EmployeeWorkplaceStripState extends State<EmployeeWorkplaceStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 196,
      child: ScrollConfiguration(
        // Тащить полосу мышью: по умолчанию Flutter принимает drag только от
        // пальца, поэтому на ПК полоса выглядела «залипшей».
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
          scrollbars: false,
        ),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          child: ListView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              _AllCard(
                isActive:
                    widget.activeFilter == AnalyticsConstants.allWorkplaces,
                onTap: () =>
                    widget.onChangeFilter(AnalyticsConstants.allWorkplaces),
              ),
              for (final row in widget.rows) ...[
                const SizedBox(width: 12),
                _WorkplaceCard(
                  row: row,
                  isActive: widget.activeFilter == row.workplaceId,
                  onTap: () => widget.onChangeFilter(row.workplaceId),
                  onOpenIncidents: widget.onOpenIncidents == null
                      ? null
                      : (type) =>
                          widget.onOpenIncidents!(row.workplaceId, type),
                ),
              ],
            ],
          ),
        ),
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
                    fontWeight: FontWeight.w600,
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
    this.onOpenIncidents,
  });
  final WorkplaceSummaryRow row;
  final bool isActive;
  final VoidCallback onTap;
  final void Function(AnalyticsEventType type)? onOpenIncidents;

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
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            // Паузы и проблемы — кнопки: открывают заказы, в которых они были.
            Row(
              children: [
                Expanded(
                  child: _IncidentButton(
                    label: 'Паузы',
                    count: row.pauseCount,
                    minutes: row.pauseMinutes,
                    color: const Color(0xFFF59E0B),
                    onPressed: onOpenIncidents == null || row.pauseCount == 0
                        ? null
                        : () => onOpenIncidents!(AnalyticsEventType.pause),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _IncidentButton(
                    label: 'Проблемы',
                    count: row.problemCount,
                    minutes: row.problemMinutes,
                    color: const Color(0xFFEF4444),
                    onPressed: onOpenIncidents == null || row.problemCount == 0
                        ? null
                        : () => onOpenIncidents!(AnalyticsEventType.problem),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Количество — последним (после времени), как и в строках
            // «Рабочие места» таблицы сотрудников.
            _kv('Сделано',
                '${AnalyticsFormat.hoursMinutes(row.workMinutes)} · ${AnalyticsFormat.decimal(row.qty)} ${row.unit}'),
            _kv('Скорость',
                '${AnalyticsFormat.decimal(row.speed)} ${row.unit}/мин'),
            _kv('Претензии', '${row.claims}'),
          ],
        ),
      ),
    );
  }

  // Значение — в Expanded: без него длинное значение занимает всю ширину
  // карточки, label сжимается в ноль и переносится по буквам — карточка
  // фиксированной высоты 168 переполняется по вертикали на 100+ px.
  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(
          children: [
            Text(
              k,
              style:
                  const TextStyle(color: AnalyticsColors.muted, fontSize: 11),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                v,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: AnalyticsColors.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
}

/// Кнопка-счётчик простоя: «Паузы 3 · 1 ч 20 мин».
///
/// Неактивна, когда простоев не было — открывать пустой список незачем.
class _IncidentButton extends StatelessWidget {
  const _IncidentButton({
    required this.label,
    required this.count,
    required this.minutes,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final int count;
  final int minutes;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: enabled ? color.withOpacity(0.12) : AnalyticsColors.bg2,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: enabled ? color.withOpacity(0.55) : AnalyticsColors.line,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: enabled ? color : AnalyticsColors.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$count · ${AnalyticsFormat.hoursMinutes(minutes)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: enabled ? AnalyticsColors.text : AnalyticsColors.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: 240,
        decoration: BoxDecoration(
          color: AnalyticsColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive ? AnalyticsColors.blue : AnalyticsColors.line,
            width: isActive ? 2 : 1,
          ),
          boxShadow: isActive
              ? const [
                  BoxShadow(
                    color: Color(0x246A6CF7),
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
