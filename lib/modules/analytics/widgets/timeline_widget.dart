import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../calculators/timeline_calculator.dart';
import '../models/analytics_event.dart';
import '../utils/analytics_colors.dart';
import '../utils/format_utils.dart';

class TimelineWidget extends StatelessWidget {
  const TimelineWidget({
    super.key,
    required this.layout,
    this.onSegmentTap,
    this.workplaceNameOf,
    this.employeeNameOf,
  });

  final TimelineLayout layout;
  final ValueChanged<TimelineSegment>? onSegmentTap;
  final String Function(String workplaceId)? workplaceNameOf;
  final String Function(String employeeId)? employeeNameOf;

  @override
  Widget build(BuildContext context) {
    final total = layout.totalMinutes;
    if (total <= 0) {
      return _emptyState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Legend(),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? math.max(constraints.maxWidth, 700.0)
              : 700.0;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TimelineBar(
                    layout: layout,
                    onSegmentTap: onSegmentTap,
                    workplaceNameOf: workplaceNameOf,
                    employeeNameOf: employeeNameOf,
                  ),
                  const SizedBox(height: 6),
                  _TimeScale(layout: layout),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _emptyState() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: AnalyticsColors.tlIdle.withOpacity(0.4),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: AnalyticsColors.line),
      ),
      alignment: Alignment.center,
      child: const Text(
        'Простой — событий нет',
        style: TextStyle(color: AnalyticsColors.muted, fontSize: 12),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: const [
        _LegendDot(color: AnalyticsColors.tlIdle, label: 'простой'),
        _LegendDot(color: AnalyticsColors.tlWork, label: 'работа'),
        _LegendDot(color: AnalyticsColors.tlSetup, label: 'наладка'),
        _LegendDot(color: AnalyticsColors.tlPause, label: 'пауза'),
        _LegendDot(color: AnalyticsColors.tlProblem, label: 'проблема'),
        _LegendDot(color: AnalyticsColors.tlOverlap, label: 'пересечение'),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(color: AnalyticsColors.muted, fontSize: 11)),
      ],
    );
  }
}

class _TimelineBar extends StatelessWidget {
  const _TimelineBar({
    required this.layout,
    this.onSegmentTap,
    this.workplaceNameOf,
    this.employeeNameOf,
  });

  final TimelineLayout layout;
  final ValueChanged<TimelineSegment>? onSegmentTap;
  final String Function(String workplaceId)? workplaceNameOf;
  final String Function(String employeeId)? employeeNameOf;

  @override
  Widget build(BuildContext context) {
    final total = layout.totalMinutes;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return Container(
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          color: AnalyticsColors.tlIdle.withOpacity(0.32),
          border: Border.all(color: AnalyticsColors.line),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Stack(
            children: layout.segments.map((seg) {
              final left = ((seg.startMinutes - layout.startMinutes) / total) *
                  width;
              final segWidth =
                  ((seg.endMinutes - seg.startMinutes) / total) * width;
              return Positioned(
                left: left,
                top: 0,
                bottom: 0,
                width: segWidth < 2 ? 2 : segWidth,
                child: _Segment(
                  segment: seg,
                  onTap: onSegmentTap,
                  workplaceNameOf: workplaceNameOf,
                  employeeNameOf: employeeNameOf,
                ),
              );
            }).toList(),
          ),
        ),
      );
    });
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.segment,
    this.onTap,
    this.workplaceNameOf,
    this.employeeNameOf,
  });
  final TimelineSegment segment;
  final ValueChanged<TimelineSegment>? onTap;
  final String Function(String workplaceId)? workplaceNameOf;
  final String Function(String employeeId)? employeeNameOf;

  Color _color() {
    if (segment.isOverlap) return AnalyticsColors.tlOverlap;
    switch (segment.type) {
      case AnalyticsEventType.work:
        return AnalyticsColors.tlWork;
      case AnalyticsEventType.setup:
        return AnalyticsColors.tlSetup;
      case AnalyticsEventType.pause:
        return AnalyticsColors.tlPause;
      case AnalyticsEventType.problem:
        return AnalyticsColors.tlProblem;
      case AnalyticsEventType.idle:
        return AnalyticsColors.tlIdle;
    }
  }

  String _label() {
    if (segment.isOverlap) return 'Пересечение';
    switch (segment.type) {
      case AnalyticsEventType.work:
        return 'Работа';
      case AnalyticsEventType.setup:
        return 'Наладка';
      case AnalyticsEventType.pause:
        return 'Пауза';
      case AnalyticsEventType.problem:
        return 'Проблема';
      case AnalyticsEventType.idle:
        return 'Простой';
    }
  }

  String _tooltipText() {
    final start = AnalyticsFormat.minutesToHHMM(segment.startMinutes);
    final end = AnalyticsFormat.minutesToHHMM(segment.endMinutes);
    final dur = segment.durationMinutes;
    final base = '${_label()} • $start–$end • $dur мин';
    final ev = segment.event;
    if (segment.isOverlap) {
      final names = segment.overlappingEvents
          .map((e) =>
              '${e.type.label}: ${workplaceNameOf?.call(e.workplaceId) ?? e.workplaceId}')
          .join('\n');
      return '$base\n$names';
    }
    if (ev == null) return base;
    final parts = <String>[base];
    final wp = workplaceNameOf?.call(ev.workplaceId);
    if (wp != null) parts.add('Рабочее место: $wp');
    final emp = employeeNameOf?.call(ev.employeeId);
    if (emp != null) parts.add('Сотрудник: $emp');
    if ((ev.customer ?? '').isNotEmpty) parts.add('Заказчик: ${ev.customer}');
    if (ev.orderId.isNotEmpty) parts.add('Заказ: ${ev.orderId}');
    if ((ev.note ?? '').isNotEmpty) parts.add('Причина: ${ev.note}');
    if (ev.qty > 0) parts.add('Кол-во: ${AnalyticsFormat.decimal(ev.qty)}');
    if (ev.setupQty > 0) {
      parts.add('Приладка: ${AnalyticsFormat.decimal(ev.setupQty)}');
    }
    if (ev.isActive) parts.add('Активно');
    return parts.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final color = _color();
    final showLabel = segment.durationMinutes >= 25;
    return Tooltip(
      message: _tooltipText(),
      waitDuration: const Duration(milliseconds: 250),
      child: GestureDetector(
        onTap: onTap == null ? null : () => onTap!(segment),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            border: const Border(
              right: BorderSide(color: Color(0x520213BC), width: 1),
            ),
          ),
          alignment: Alignment.center,
          child: showLabel
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    _label(),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: segment.type == AnalyticsEventType.pause
                          ? const Color(0xFF111827)
                          : Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _TimeScale extends StatelessWidget {
  const _TimeScale({required this.layout});
  final TimelineLayout layout;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final total = layout.totalMinutes;
      return SizedBox(
        height: 16,
        child: Stack(
          children: layout.hourlyTicks.map((tick) {
            final left = ((tick - layout.startMinutes) / total) * width;
            return Positioned(
              left: left - 12,
              top: 0,
              child: Text(
                AnalyticsFormat.minutesToHHMM(tick),
                style: const TextStyle(
                  color: AnalyticsColors.muted2,
                  fontSize: 10,
                ),
              ),
            );
          }).toList(),
        ),
      );
    });
  }
}
